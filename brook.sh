#!/usr/bin/env bash
# =========================================================
# Brook 一键管理脚本（菜单版 + 自动 DDNS 更新 + 官方最新版 core -t）
# 原作者：Toyo   二次整理 & 重构：AKA668 + ChatGPT
#
# 使用方式：
#   bash <(curl -Ls https://raw.githubusercontent.com/AKA668/brook/main/brook.sh)
#   之后可直接输入： brook  打开菜单
#
# 主要特性：
#   - 使用官方最新版 Brook core（txthinking/brook）
#   - 使用 relay -l :PORT -t HOST:PORT 语法（新版，不再用 -r）
#   - 按规则文件管理端口转发（支持域名 + DDNS 自动更新）
#   - 自动安装为命令：brook
#   - 默认启动 DDNS 守护进程（监控域名 IP 变化，自动重启对应转发）
#
# 菜单功能：
#   0. 升级管理脚本（重新拉取 GitHub 上的 brook.sh）
#   1. 安装 Brook 核心
#   2. 更新 Brook 核心
#   3. 卸载 Brook
#   4. 启动 Brook 端口转发（根据规则文件）
#   5. 停止 Brook 端口转发
#   6. 重启 Brook 端口转发
#   7. 设置端口转发（单条/批量增删）
#   8. 查看端口转发
#   9. 查看日志
#  10. 查看 DDNS 最新解析 IP
#  11. 查看运行状态
# =========================================================

set -e

# ------------------ 全局变量 ------------------
sh_ver="2.0.0"

BROOK_CORE="/usr/local/bin/brook_core"     # 官方 core 可执行文件
BROOK_MENU="/usr/local/bin/brook"          # 菜单命令（本脚本自身安装到这里）
RULE_FILE="/etc/brook_rules.conf"          # 规则文件
LOG_DIR="/var/log/brook"                   # 各规则日志 + ddns.log
PID_DIR="/var/run"                         # PID 文件目录
DDNS_CACHE_DIR="/var/run/brook_ddns"       # 各规则当前 IP 缓存
DDNS_INTERVAL=10                           # DDNS 检查间隔（秒）

C_GREEN="\033[32m"
C_RED="\033[31m"
C_YELLOW="\033[33m"
C_RESET="\033[0m"

green(){ echo -e "${C_GREEN}$*${C_RESET}"; }
red(){ echo -e "${C_RED}$*${C_RESET}"; }
yellow(){ echo -e "${C_YELLOW}$*${C_RESET}"; }
pause(){ read -rp "按回车键继续..." _; }

require_root(){
  if [[ $EUID -ne 0 ]]; then
    red "❌ 当前非 root 用户，请先执行：sudo -i  或在前面加 sudo"
    exit 1
  fi
}

init_env(){
  mkdir -p "$(dirname "$RULE_FILE")" "$LOG_DIR" "$DDNS_CACHE_DIR"
  touch "$RULE_FILE"
}

# ------------------ 脚本自升级（菜单 0） ------------------
update_shell(){
  local url="https://raw.githubusercontent.com/AKA668/brook/main/brook.sh"
  local tmp
  tmp=$(mktemp)

  yellow "▶ 正在从 GitHub 拉取最新管理脚本..."
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$tmp"
  else
    wget -qO "$tmp" "$url"
  fi

  chmod +x "$tmp"
  # 覆盖当前脚本文件（如果是通过本地文件执行）
  if [[ -f "$0" && -w "$0" ]]; then
    cp "$tmp" "$0"
    green "✔ 管理脚本已更新为最新版本（v${sh_ver} 可能会变更，以实际为准）"
    yellow "▶ 请重新执行脚本或直接输入 brook 运行新版本。"
  else
    green "✔ 已下载最新脚本到：$tmp"
    yellow "如需手动替换，请自行拷贝到目标位置。"
  fi
  exit 0
}

# ------------------ Brook core 下载相关 ------------------
detect_arch(){
  case "$(uname -m)" in
    x86_64|amd64)   echo "brook_linux_amd64" ;;
    i386|i686)      echo "brook_linux_386" ;;
    armv7l|armv7)   echo "brook_linux_arm7" ;;
    armv6l|armv6)   echo "brook_linux_arm6" ;;
    aarch64|arm64)  echo "brook_linux_arm64" ;;
    mips)           echo "brook_linux_mips" ;;
    mipsle)         echo "brook_linux_mipsle" ;;
    mips64)         echo "brook_linux_mips64" ;;
    mips64le)       echo "brook_linux_mips64le" ;;
    *)              echo "" ;;
  esac
}

download_brook_core(){
  local file url tmp
  file=$(detect_arch)
  [[ -z "$file" ]] && { red "❌ 不支持的 CPU 架构：$(uname -m)"; exit 1; }

  url="https://github.com/txthinking/brook/releases/latest/download/${file}"

  yellow "▶ 正在从官方仓库下载 Brook 核心：${file}"
  tmp=$(mktemp)

  if command -v curl >/dev/null 2>&1; then
    curl -L -o "$tmp" "$url"
  else
    wget -O "$tmp" "$url"
  fi

  mv "$tmp" "$BROOK_CORE"
  chmod +x "$BROOK_CORE"

  green "✔ Brook 核心安装/更新成功：$BROOK_CORE"
}

is_core_installed(){
  [[ -x "$BROOK_CORE" ]]
}

install_brook_core(){
  download_brook_core
}

upgrade_brook_core(){
  download_brook_core
}

update_brook_core(){
  download_brook_core
}

uninstall_brook(){
  if is_core_installed; then
    read -rp "确认卸载 Brook 核心？[y/N]：" c
    if [[ "$c" =~ ^[yY]$ ]]; then
      rm -f "$BROOK_CORE"
      green "✔ 已卸载 Brook 核心文件：$BROOK_CORE"
    fi
  fi

  read -rp "是否清空所有转发规则？[y/N]：" c2
  if [[ "$c2" =~ ^[yY]$ ]]; then
    rm -f "$RULE_FILE"
    touch "$RULE_FILE"
    green "✔ 已清空规则文件：$RULE_FILE"
  fi
}

# ------------------ 规则管理（规则文件格式：id|lp|host|rp|remark） ------------------
next_rule_id(){
  if [[ ! -s "$RULE_FILE" ]]; then
    echo 1
    return
  fi
  awk -F'|' '{if($1+0>max)max=$1}END{if(max=="")max=0;print max+1}' "$RULE_FILE"
}

print_rules(){
  if [[ ! -s "$RULE_FILE" ]]; then
    yellow "当前没有任何转发规则。"
    return
  fi

  printf "\n%-4s %-10s %-25s %-10s %-s\n" "ID" "本地端口" "目标主机" "目标端口" "备注"
  printf "%-4s %-10s %-25s %-10s %-s\n" "----" "--------" "------------------------" "----------" "--------"

  while IFS='|' read -r id lp host rp remark; do
    [[ -z "$id" ]] && continue
    printf "%-4s %-10s %-25s %-10s %-s\n" "$id" "$lp" "$host" "$rp" "$remark"
  done < "$RULE_FILE"
  echo
}

add_single_rule(){
  yellow "▶ 添加单条转发规则"
  read -rp "本地监听端口: " lp
  read -rp "目标主机（域名或IP）: " host
  read -rp "目标端口: " rp
  read -rp "备注（可空）: " remark

  [[ -z "$lp" || -z "$host" || -z "$rp" ]] && { red "❌ 必填项不能为空"; return; }

  local id
  id=$(next_rule_id)
  echo "$id|$lp|$host|$rp|$remark" >> "$RULE_FILE"
  green "✔ 规则已添加：ID=$id  :$lp → $host:$rp"
}

add_batch_rules(){
  yellow "▶ 批量添加规则（空行结束）"
  echo "格式：本地端口  目标主机  目标端口  备注(可选)"
  echo "示例：10000  my.ddns.com  3389  家里电脑远程"

  while true; do
    read -rp "> " line
    [[ -z "$line" ]] && break
    lp=$(echo "$line" | awk '{print $1}')
    host=$(echo "$line" | awk '{print $2}')
    rp=$(echo "$line" | awk '{print $3}')
    remark=$(echo "$line" | cut -d ' ' -f4-)

    if [[ -z "$lp" || -z "$host" || -z "$rp" ]]; then
      red "❌ 参数不足，已跳过该行。"
      continue
    fi
    id=$(next_rule_id)
    echo "$id|$lp|$host|$rp|$remark" >> "$RULE_FILE"
    green "  → 已添加规则 ID=$id  :$lp → $host:$rp"
  done

  green "✔ 批量添加完成。"
}

delete_rules(){
  print_rules
  read -rp "请输入要删除的规则 ID（空格分隔）: " ids
  [[ -z "$ids" ]] && return

  for id in $ids; do
    stop_rule "$id"
  done

  tmp=$(mktemp)
  while IFS='|' read -r id lp host rp remark; do
    [[ -z "$id" ]] && continue
    skip=0
    for d in $ids; do
      [[ "$d" == "$id" ]] && skip=1
    done
    [[ $skip -eq 1 ]] && continue
    echo "$id|$lp|$host|$rp|$remark" >> "$tmp"
  done < "$RULE_FILE"

  mv "$tmp" "$RULE_FILE"
  green "✔ 指定规则已删除。"
}

# ------------------ DNS 工具 ------------------
resolve_host_realtime(){
  local host="$1"

  # 已经是 IP 直接返回
  if [[ "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "$host"
    return
  fi

  # getent
  if command -v getent >/dev/null 2>&1; then
    getent hosts "$host" | awk '{print $1}' | head -n1 && return
  fi

  # dig
  if command -v dig >/dev/null 2>&1; then
    dig +short "$host" | grep -E '^[0-9.]+' | head -n1 && return
  fi

  # ping
  ping -c1 -W1 "$host" 2>/dev/null | awk -F'[()]' '/PING/{print $2}' | head -n1
}

# ------------------ 启动/停止单条规则（官方新版 relay -t） ------------------
start_rule(){
  local id="$1" lp="$2" host="$3" rp="$4" ip_override="$5"

  local pid_file="$PID_DIR/brook_${id}.pid"
  local log_file="$LOG_DIR/${id}.log"

  # 如果已有进程，且还在运行，则跳过
  if [[ -f "$pid_file" ]]; then
    local oldpid
    oldpid=$(cat "$pid_file" 2>/dev/null || echo "")
    if [[ -n "$oldpid" && -d "/proc/$oldpid" ]]; then
      yellow "规则 $id 已在运行中（PID $oldpid），跳过启动。"
      return
    fi
  fi

  local ip
  if [[ -n "$ip_override" ]]; then
    ip="$ip_override"
  else
    ip=$(resolve_host_realtime "$host")
  fi
  [[ -z "$ip" ]] && ip="解析失败"

  echo "$ip" > "$DDNS_CACHE_DIR/$id.ip"

  # ⭐ 使用新版 relay 参数：-t 目标，不再使用 -r
  nohup "$BROOK_CORE" relay -l ":$lp" -t "${ip}:$rp" >>"$log_file" 2>&1 &
  local pid=$!
  echo "$pid" > "$pid_file"

  green "✔ 启动规则 $id 成功：:$lp → $host($ip):$rp (PID: $pid)"
}

stop_rule(){
  local id="$1"
  local pid_file="$PID_DIR/brook_${id}.pid"

  [[ ! -f "$pid_file" ]] && return

  local pid
  pid=$(cat "$pid_file" 2>/dev/null || echo "")
  [[ -z "$pid" ]] && { rm -f "$pid_file"; return; }

  kill "$pid" 2>/dev/null || true
  sleep 0.3
  [[ -d "/proc/$pid" ]] && kill -9 "$pid" 2>/dev/null || true

  rm -f "$pid_file"
  green "✔ 已停止规则 $id"
}

# ------------------ 启动/停止所有规则 ------------------
start_all(){
  if ! is_core_installed; then
    red "❌ 未检测到 Brook 核心，请先执行：1. 安装 Brook"
    return
  fi
  if [[ ! -s "$RULE_FILE" ]]; then
    yellow "⚠ 当前没有任何规则，无法启动转发。请先在菜单 7 里添加规则。"
    return
  fi

  while IFS='|' read -r id lp host rp remark; do
    [[ -z "$id" ]] && continue
    start_rule "$id" "$lp" "$host" "$rp"
  done < "$RULE_FILE"

  ddns_monitor_start
}

stop_all(){
  for f in "$PID_DIR"/brook_*.pid; do
    [[ -f "$f" ]] || break
    id=$(basename "$f" | sed 's/brook_//' | sed 's/.pid//')
    stop_rule "$id"
  done
  ddns_monitor_stop
}

# ------------------ 状态 ------------------
status_all(){
  if [[ ! -s "$RULE_FILE" ]]; then
    yellow "当前没有规则。"
    return
  fi

  printf "\n%-4s %-10s %-10s %-25s %-10s %-s\n" "ID" "本地端口" "状态" "目标主机" "目标端口" "备注"
  printf "%-4s %-10s %-10s %-25s %-10s %-s\n" "----" "--------" "--------" "------------------------" "----------" "--------"

  while IFS='|' read -r id lp host rp remark; do
    [[ -z "$id" ]] && continue
    local pid_file="$PID_DIR/brook_${id}.pid"
    local status="stopped"
    if [[ -f "$pid_file" ]]; then
      local pid
      pid=$(cat "$pid_file" 2>/dev/null || echo "")
      if [[ -n "$pid" && -d "/proc/$pid" ]]; then
        status="running($pid)"
      fi
    fi
    printf "%-4s %-10s %-10s %-25s %-10s %-s\n" "$id" "$lp" "$status" "$host" "$rp" "$remark"
  done < "$RULE_FILE"
  echo
}

# ------------------ 日志 ------------------
view_logs(){
  print_rules
  read -rp "请输入要查看日志的规则 ID：" id
  [[ -z "$id" ]] && { yellow "已取消。"; return; }

  local log="$LOG_DIR/$id.log"
  if [[ ! -f "$log" ]]; then
    yellow "该规则暂无日志文件：$log"
    return
  fi

  yellow "▶ 正在实时查看日志（Ctrl + C 退出）"
  tail -f "$log"
}

# ------------------ 查看 DDNS 最新解析 IP（菜单 10） ------------------
show_ddns_ips(){
  if [[ ! -s "$RULE_FILE" ]]; then
    yellow "当前没有规则。"
    return
  fi

  printf "\n%-4s %-25s %-20s %-s\n" "ID" "主机" "当前解析IP" "备注"
  printf "%-4s %-25s %-20s %-s\n" "----" "------------------------" "--------------------" "--------"

  while IFS='|' read -r id lp host rp remark; do
    [[ -z "$id" ]] && continue
    local ip
    ip=$(resolve_host_realtime "$host")
    [[ -z "$ip" ]] && ip="解析失败"
    printf "%-4s %-25s %-20s %-s\n" "$id" "$host" "$ip" "$remark"
  done < "$RULE_FILE"
  echo
}

# ------------------ DDNS 自动监控 ------------------
ddns_monitor_loop(){
  local log="$LOG_DIR/ddns.log"
  echo "DDNS 监控已启动（间隔 ${DDNS_INTERVAL}s）" > "$log"

  while true; do
    if [[ ! -s "$RULE_FILE" ]]; then
      sleep "$DDNS_INTERVAL"
      continue
    fi

    while IFS='|' read -r id lp host rp remark; do
      [[ -z "$id" ]] && continue

      local new_ip
      new_ip=$(resolve_host_realtime "$host")
      [[ -z "$new_ip" ]] && new_ip="解析失败"

      local cache="$DDNS_CACHE_DIR/$id.ip"
      local old_ip=""
      [[ -f "$cache" ]] && old_ip=$(cat "$cache" 2>/dev/null || echo "")

      if [[ "$new_ip" != "$old_ip" && "$new_ip" != "解析失败" ]]; then
        echo "$(date '+%F %T') [DDNS] 规则 $id | $host IP 变化：$old_ip → $new_ip" >> "$log"
        # 停掉旧规则 & 用新 IP 启动
        stop_rule "$id"
        start_rule "$id" "$lp" "$host" "$rp" "$new_ip"
        echo "$(date '+%F %T') [DDNS] 已用新 IP 重启规则 $id" >> "$log"
      fi
    done < "$RULE_FILE"

    sleep "$DDNS_INTERVAL"
  done
}

ddns_monitor_start(){
  # pid 文件存在且进程存在 → 不重复启动
  if [[ -f /var/run/brook_ddns.pid ]]; then
    local pid
    pid=$(cat /var/run/brook_ddns.pid 2>/dev/null || echo "")
    if [[ -n "$pid" && -d "/proc/$pid" ]]; then
      #yellow "DDNS 自动更新已在运行中 (PID $pid)。"
      return
    else
      rm -f /var/run/brook_ddns.pid
    fi
  fi

  # 通过自身脚本的隐藏模式 --ddns-monitor 启动守护
  nohup "$BROOK_MENU" --ddns-monitor >/dev/null 2>&1 &
  echo $! > /var/run/brook_ddns.pid
  green "✔ DDNS 自动更新守护进程已启动。"
}

ddns_monitor_stop(){
  if [[ -f /var/run/brook_ddns.pid ]]; then
    local pid
    pid=$(cat /var/run/brook_ddns.pid 2>/dev/null || echo "")
    if [[ -n "$pid" && -d "/proc/$pid" ]]; then
      kill "$pid" 2>/dev/null || true
      sleep 0.3
      [[ -d "/proc/$pid" ]] && kill -9 "$pid" 2>/dev/null || true
      green "✔ 已停止 DDNS 自动更新守护进程 (PID $pid)。"
    fi
    rm -f /var/run/brook_ddns.pid
  fi
}

# ------------------ 安装自身为 brook 命令 ------------------
self_install_menu(){
  local target="/usr/local/bin/brook"
  local self_path

  # 获取当前脚本真实路径
  self_path=$(readlink -f "$0" 2>/dev/null || echo "$0")

  if [[ "$self_path" != "$target" ]]; then
    cp -f "$self_path" "$target"
    chmod +x "$target"
    echo -e "${C_GREEN}[OK]${C_RESET} 已安装命令：brook  （以后可直接输入 brook 打开菜单）"
  fi
}

# ------------------ 菜单 UI ------------------
show_menu(){
  clear
  echo "┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓"
  echo "┃ Brook 端口转发 一键管理脚本 [v${sh_ver}] ┃"
  echo "┃   机场搭建 ❤ 机场托管 ❤ 技术支持       ┃"
  echo "┃   Telegram: https://t.me/bojiiking  ┃"
  echo "┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛"
  echo "━━━━━━━━━━━━ 功能菜单 ━━━━━━━━━━━━"
  echo "  0. 升级管理脚本（重新拉取 brook.sh）"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  1. 安装 Brook 核心"
  echo "  2. 更新 Brook 核心"
  echo "  3. 卸载 Brook（可选清空规则）"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  4. 启动 Brook 转发（根据规则文件）"
  echo "  5. 停止 Brook 转发"
  echo "  6. 重启 Brook 转发"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  7. 设置端口转发（单条/批量增删）"
  echo "  8. 查看端口转发"
  echo "  9. 查看规则日志"
  echo " 10. 查看 DDNS 最新解析 IP"
  echo " 11. 查看运行状态"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  if is_core_installed; then
    local running
    running=$(ls "$PID_DIR"/brook_*.pid 2>/dev/null | wc -l)
    if [[ "$running" -gt 0 ]]; then
      echo -e " 当前状态：${C_GREEN}已安装 / 有运行中的规则${C_RESET}"
    else
      echo -e " 当前状态：${C_GREEN}已安装 / 未运行${C_RESET}"
    fi
  else
    echo -e " 当前状态：${C_RED}未安装 Brook 核心${C_RESET}"
  fi

  echo
  echo -n " 请输入数字 [0-11]: "
}

menu_forward(){
  while true; do
    clear
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  7. 端口转发管理（子菜单）"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  1. 添加单条规则"
    echo "  2. 批量添加规则"
    echo "  3. 批量删除规则"
    echo "  0. 返回主菜单"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    read -rp "请选择 [0-3]: " s
    case "$s" in
      1) add_single_rule; pause ;;
      2) add_batch_rules; pause ;;
      3) delete_rules; pause ;;
      0) break ;;
      *) red "无效选项，请输入 0-3"; sleep 1 ;;
    esac
  done
}

# ------------------ 主入口 ------------------
main(){
  require_root
  init_env

  # 隐藏模式：仅用于 DDNS 守护进程
  if [[ "$1" == "--ddns-monitor" ]]; then
    ddns_monitor_loop
    exit 0
  fi

  # 先安装自身为 brook 命令
  self_install_menu

  # 默认启动 DDNS 自动更新守护（如果已经运行则不会重复启）
  ddns_monitor_start

  # 主循环菜单：只要用户输入 brook，就一直显示菜单
  while true; do
    show_menu
    read -r num
    case "$num" in
      0) update_shell ;;
      1) install_brook_core; pause ;;
      2) update_brook_core; pause ;;
      3) uninstall_brook; pause ;;
      4) start_all; pause ;;
      5) stop_all; pause ;;
      6) stop_all; start_all; pause ;;
      7) menu_forward ;;
      8) print_rules; pause ;;
      9) view_logs ;;
      10) show_ddns_ips; pause ;;
      11) status_all; pause ;;
      *) red "无效选项，请输入 0-11"; sleep 1 ;;
    esac
  done
}

main "$@"
