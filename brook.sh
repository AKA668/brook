#!/usr/bin/env bash
# =========================================================
# Brook 一键管理脚本（菜单版 + 自动 DDNS 更新）
# 作者：AKA668（逻辑协助 by ChatGPT）
#
# 功能菜单：
#   0. 升级brook核心   （强制重新下载官方最新版）
#   1. 安装 Brook       （首次安装）
#   2. 更新 Brook       （覆盖更新核心）
#   3. 卸载 Brook       （卸载核心，可选保留规则）
#   4. 启动 Brook       （启动全部规则 + 启动 DDNS 监控）
#   5. 停止 Brook       （停止全部规则 + 停止 DDNS 监控）
#   6. 重启 Brook       （先停后启）
#   7. 设置 Brook 端口转发（可批量：单条 / 批量添加 / 批量删除）
#   8. 查看 Brook 端口转发
#   9. 查看 Brook 日志（tail -f）
#  10. 查看 DDNS 最新域名 IP
#  11. 查看 Brook 运行状态
#
# 说明：
#   - 本脚本安装为：/usr/local/bin/brook（菜单入口命令）
#   - Brook 核心安装为：/usr/local/bin/brook_core
#   - 规则保存：/etc/brook_rules.conf
#   - 日志目录：/var/log/brook/
#   - PID 文件：/var/run/brook_*.pid
#   - DDNS 缓存：/var/run/brook_ddns/*.ip
#   - DDNS 监控后台进程 PID：/var/run/brook_ddns.pid
# =========================================================

set -e

# ------------------ 全局变量 ------------------
BROOK_CORE="/usr/local/bin/brook_core"   # brook 内核
BROOK_MENU="/usr/local/bin/brook"        # 菜单命令自身
RULE_FILE="/etc/brook_rules.conf"
LOG_DIR="/var/log/brook"
PID_DIR="/var/run"

DDNS_INTERVAL=10                         # DDNS 检测间隔（秒）
DDNS_CACHE_DIR="/var/run/brook_ddns"     # 每条规则对应的最新 IP 缓存

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
    red "❌ 请使用 root 用户运行本脚本（sudo -i 或 sudo bash brook.sh）"
    exit 1
  fi
}

init_env(){
  mkdir -p "$(dirname "$RULE_FILE")" "$LOG_DIR" "$DDNS_CACHE_DIR"
  touch "$RULE_FILE"
}

# ------------------ Brook 下载相关 ------------------
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
  [[ -z "$file" ]] && { red "❌ 暂不支持此架构：$(uname -m)，请手动安装 Brook。"; exit 1; }

  url="https://github.com/txthinking/brook/releases/latest/download/${file}"

  yellow "▶ 正在从官方 GitHub 下载 Brook 核心（${file}）..."
  tmp=$(mktemp)

  if command -v curl >/dev/null 2>&1; then
    curl -L -o "$tmp" "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "$tmp" "$url"
  else
    red "❌ 未检测到 curl 或 wget，请先安装其中之一。"
    exit 1
  fi

  mv "$tmp" "$BROOK_CORE"
  chmod +x "$BROOK_CORE"

  green "✔ Brook 核心已安装到：$BROOK_CORE"
}

is_core_installed(){
  [[ -x "$BROOK_CORE" ]]
}

install_brook(){
  if is_core_installed; then
    yellow "⚠ 检测到已安装 Brook 核心：$BROOK_CORE"
    read -rp "是否覆盖安装最新版本？[y/N]：" c
    [[ ! "$c" =~ ^[yY]$ ]] && { yellow "已取消安装。"; return; }
  fi
  download_brook_core
}

upgrade_brook(){
  yellow "▶ 正在升级 Brook 核心到官方最新版本..."
  download_brook_core
}

update_brook(){
  yellow "▶ 正在更新 Brook 核心到官方最新版本..."
  download_brook_core
}

uninstall_brook(){
  if is_core_installed; then
    read -rp "确认卸载 Brook 核心？[y/N]：" c
    if [[ "$c" =~ ^[yY]$ ]]; then
      rm -f "$BROOK_CORE"
      green "✔ 已卸载 Brook 核心。"
    else
      yellow "已取消卸载。"
    fi
  else
    yellow "⚠ 未检测到 Brook 核心，无需卸载。"
  fi

  read -rp "是否同时清空端口转发规则？[y/N]：" c2
  if [[ "$c2" =~ ^[yY]$ ]]; then
    rm -f "$RULE_FILE"
    touch "$RULE_FILE"
    green "✔ 已清空规则文件：$RULE_FILE"
  fi
}

# ------------------ 规则相关 ------------------
next_rule_id(){
  if [[ ! -s "$RULE_FILE" ]]; then
    echo 1
    return
  fi
  awk -F'|' '{if($1+0>max)max=$1+0}END{if(max=="")max=0;print max+1}' "$RULE_FILE"
}

print_rules(){
  if [[ ! -s "$RULE_FILE" ]]; then
    yellow "当前没有任何端口转发规则。"
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
  echo
  yellow "▶ 添加单条端口转发规则"
  read -rp "本地端口（例如 2333）： " lp
  [[ -z "$lp" ]] && { red "❌ 本地端口不能为空。"; return; }

  read -rp "目标主机（支持域名或IP，例如 myddns.xxx.com 或 1.2.3.4）： " host
  [[ -z "$host" ]] && { red "❌ 目标主机不能为空。"; return; }

  read -rp "目标端口（例如 6666）： " rp
  [[ -z "$rp" ]] && { red "❌ 目标端口不能为空。"; return; }

  read -rp "备注（可留空）： " remark

  local id
  id=$(next_rule_id)
  echo "$id|$lp|$host|$rp|$remark" >> "$RULE_FILE"
  green "✔ 已添加规则：ID=$id  :$lp → $host:$rp  [$remark]"
}

add_batch_rules(){
  echo
  yellow "▶ 批量添加端口转发规则"
  echo "格式： 本地端口  目标主机(域名或IP)  目标端口  备注(可选)"
  echo "示例：2333  myddns.example.com  6666  香港游戏1"
  echo "示例：2334  1.2.3.4            7777  直连节点"
  echo "直接回车结束批量录入。"
  echo

  while true; do
    read -rp "> " line
    [[ -z "$line" ]] && break

    local lp host rp remark
    lp=$(echo "$line" | awk '{print $1}')
    host=$(echo "$line" | awk '{print $2}')
    rp=$(echo "$line" | awk '{print $3}')
    remark=$(echo "$line" | cut -d ' ' -f4-)

    if [[ -z "$lp" || -z "$host" || -z "$rp" ]]; then
      red "❌ 格式错误，至少需要：本地端口  目标主机  目标端口"
      continue
    fi

    local id
    id=$(next_rule_id)
    echo "$id|$lp|$host|$rp|$remark" >> "$RULE_FILE"
    green "  → 已添加规则：ID=$id  :$lp → $host:$rp  [$remark]"
  done

  echo
  green "✔ 批量添加完成。"
}

delete_rules(){
  print_rules
  read -rp "请输入要删除的规则 ID（可多个，空格分隔）： " ids
  [[ -z "$ids" ]] && { yellow "未输入 ID，已取消删除。"; return; }

  for id in $ids; do
    stop_rule "$id"
  done

  local tmp
  tmp=$(mktemp)
  while IFS='|' read -r id lp host rp remark; do
    [[ -z "$id" ]] && continue
    local skip=0
    for del in $ids; do
      if [[ "$del" == "$id" ]]; then
        skip=1
        break
      fi
    done
    [[ $skip -eq 1 ]] && continue
    echo "$id|$lp|$host|$rp|$remark" >> "$tmp"
  done < "$RULE_FILE"

  mv "$tmp" "$RULE_FILE"
  green "✔ 删除完成。"
}

# ------------------ DNS 解析工具 ------------------
resolve_host_realtime(){
  local host="$1"

  # 如果本身就是 IPv4，直接返回
  if [[ "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "$host"
    return
  fi

  # 优先 getent
  if command -v getent >/dev/null 2>&1; then
    getent hosts "$host" | awk '{print $1}' | head -n1 && return
  fi

  # 再 dig
  if command -v dig >/dev/null 2>&1; then
    dig +short "$host" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n1 && return
  fi

  # 再 ping
  if command -v ping >/dev/null 2>&1; then
    ping -c1 -W1 "$host" 2>/dev/null | awk -F'[()]' '/PING/{print $2}' | head -n1 && return
  fi

  # 实在不行就返回原值
  echo "$host"
}

# ------------------ 启动 / 停止规则 ------------------
start_rule(){
  local id="$1" lp="$2" host="$3" rp="$4" ip_override="$5"
  local pid_file="$PID_DIR/brook_${id}.pid"
  local log_file="$LOG_DIR/${id}.log"

  # 如果已有 PID 且还活着，直接略过
  if [[ -f "$pid_file" ]]; then
    local oldpid
    oldpid=$(cat "$pid_file" 2>/dev/null || true)
    if [[ -n "$oldpid" && -d "/proc/$oldpid" ]]; then
      yellow "规则 $id 已在运行中 (PID $oldpid)，跳过。"
      return
    fi
  fi

  local ip
  if [[ -n "$ip_override" ]]; then
    ip="$ip_override"
  else
    ip=$(resolve_host_realtime "$host")
  fi

  echo "$ip" > "$DDNS_CACHE_DIR/$id.ip"

  nohup "$BROOK_CORE" relay -l ":$lp" -r "${ip}:$rp" >>"$log_file" 2>&1 &
  local pid=$!
  echo "$pid" > "$pid_file"

  green "✔ 已启动规则 $id (PID $pid)：:$lp → $host($ip):$rp"
}

stop_rule(){
  local id="$1"
  local pid_file="$PID_DIR/brook_${id}.pid"

  if [[ ! -f "$pid_file" ]]; then
    return
  fi

  local pid
  pid=$(cat "$pid_file" 2>/dev/null || true)
  if [[ -z "$pid" ]]; then
    rm -f "$pid_file"
    return
  fi

  kill "$pid" 2>/dev/null || true
  sleep 0.3
  if [[ -d "/proc/$pid" ]]; then
    kill -9 "$pid" 2>/dev/null || true
  fi
  rm -f "$pid_file"
  green "✔ 已停止规则 $id (PID $pid)"
}

start_all(){
  if ! is_core_installed; then
    red "❌ 尚未安装 Brook 核心，请先执行 [1] 安装。"
    return
  fi
  if [[ ! -s "$RULE_FILE" ]]; then
    yellow "⚠ 当前没有规则，无法启动。"
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
    [[ -e "$f" ]] || break
    local id
    id=$(basename "$f" .pid | sed 's/^brook_//')
    stop_rule "$id"
  done

  ddns_monitor_stop
}

status_all(){
  if [[ ! -s "$RULE_FILE" ]]; then
    yellow "当前没有任何规则。"
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
      pid=$(cat "$pid_file" 2>/dev/null || true)
      if [[ -n "$pid" && -d "/proc/$pid" ]]; then
        status="running($pid)"
      fi
    fi
    printf "%-4s %-10s %-10s %-25s %-10s %-s\n" "$id" "$lp" "$status" "$host" "$rp" "$remark"
  done < "$RULE_FILE"

  echo
}

# ------------------ 日志 & DDNS IP 查看 ------------------
view_logs(){
  if [[ ! -d "$LOG_DIR" ]]; then
    yellow "暂无日志目录：$LOG_DIR"
    return
  fi

  print_rules
  read -rp "请输入要查看日志的规则 ID（单个）： " id
  [[ -z "$id" ]] && { yellow "已取消。"; return; }

  local log_file="$LOG_DIR/${id}.log"
  if [[ ! -f "$log_file" ]]; then
    yellow "该规则当前没有日志文件：$log_file"
    return
  fi

  echo
  yellow "▶ 正在实时跟踪日志（Ctrl + C 退出）"
  tail -f "$log_file"
}

show_ddns_ips(){
  if [[ ! -s "$RULE_FILE" ]]; then
    yellow "当前没有规则。"
    return
  fi

  echo
  yellow "▶ DDNS 最新域名 IP 查询"
  printf "\n%-4s %-25s %-25s %-s\n" "ID" "主机" "当前解析 IP" "备注"
  printf "%-4s %-25s %-25s %-s\n" "----" "------------------------" "------------------------" "--------"

  while IFS='|' read -r id lp host rp remark; do
    [[ -z "$id" ]] && continue
    local ip
    ip=$(resolve_host_realtime "$host")
    [[ -z "$ip" ]] && ip="解析失败"
    printf "%-4s %-25s %-25s %-s\n" "$id" "$host" "$ip" "$remark"
  done < "$RULE_FILE"

  echo
}

# ------------------ DDNS 自动监控（核心） ------------------
ddns_monitor_loop(){
  local LOGFILE="$LOG_DIR/ddns.log"
  echo "DDNS 监控已启动（每 ${DDNS_INTERVAL} 秒检测一次）" > "$LOGFILE"

  while true; do
    while IFS='|' read -r id lp host rp remark; do
      [[ -z "$id" ]] && continue

      # 只对域名进行监控；如果是纯 IP，就不会变化
      local new_ip
      new_ip=$(resolve_host_realtime "$host")
      [[ -z "$new_ip" ]] && new_ip="解析失败"

      local cache_file="$DDNS_CACHE_DIR/$id.ip"
      local old_ip=""
      [[ -f "$cache_file" ]] && old_ip=$(cat "$cache_file")

      if [[ "$new_ip" != "$old_ip" && "$new_ip" != "解析失败" ]]; then
        echo "$(date '+%F %T') 规则 $id | $host IP 变化：$old_ip → $new_ip" >> "$LOGFILE"

        # 停止旧规则
        stop_rule "$id"

        # 使用新 IP 启动
        start_rule "$id" "$lp" "$host" "$rp" "$new_ip"

        echo "$(date '+%F %T') 已基于新 IP 启动规则 $id" >> "$LOGFILE"
      fi

    done < "$RULE_FILE"

    sleep "$DDNS_INTERVAL"
  done
}

ddns_monitor_start(){
  # 避免重复启动
  if [[ -f /var/run/brook_ddns.pid ]]; then
    local pid
    pid=$(cat /var/run/brook_ddns.pid 2>/dev/null || true)
    if [[ -n "$pid" && -d "/proc/$pid" ]]; then
      yellow "DDNS 自动更新监控已在运行中 (PID $pid)。"
      return
    else
      rm -f /var/run/brook_ddns.pid
    fi
  fi

  nohup "$BROOK_MENU" --ddns-monitor >/dev/null 2>&1 &
  echo $! >/var/run/brook_ddns.pid
  green "✔ 已启动 DDNS 自动更新守护进程。"
}

ddns_monitor_stop(){
  if [[ -f /var/run/brook_ddns.pid ]]; then
    local pid
    pid=$(cat /var/run/brook_ddns.pid 2>/dev/null || true)
    if [[ -n "$pid" && -d "/proc/$pid" ]]; then
      kill "$pid" 2>/dev/null || true
      sleep 0.3
      if [[ -d "/proc/$pid" ]]; then
        kill -9 "$pid" 2>/dev/null || true
      fi
      green "✔ 已停止 DDNS 自动更新守护进程 (PID $pid)。"
    fi
    rm -f /var/run/brook_ddns.pid
  fi
}

# ------------------ 安装自身为 brook 命令 ------------------
self_install_menu(){
  # 只在可解析真实路径时执行
  if [[ -f "$0" ]]; then
    local self_path
    self_path=$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")
    if [[ "$self_path" != "$BROOK_MENU" ]]; then
      cp "$self_path" "$BROOK_MENU"
      chmod +x "$BROOK_MENU"
      green "✔ 已将本脚本安装为命令：brook"
    fi
  fi
}

# ------------------ 菜单 UI ------------------
show_menu(){
  clear
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  0. 升级brook核心"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  1. 安装 Brook"
  echo "  2. 更新 Brook"
  echo "  3. 卸载 Brook"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  4. 启动 Brook"
  echo "  5. 停止 Brook"
  echo "  6. 重启 Brook"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  7. 设置 Brook 端口转发（可批量）"
  echo "  8. 查看 Brook 端口转发"
  echo "  9. 查看 Brook 日志"
  echo " 10. 查看 DDNS 最新域名 IP"
  echo " 11. 查看 Brook 运行状态"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo

  if is_core_installed; then
    # 粗略判断是否有运行中
    local running_count
    running_count=$(ls "$PID_DIR"/brook_*.pid 2>/dev/null | wc -l || echo 0)
    if [[ "$running_count" -gt 0 ]]; then
      echo -e " 当前状态: ${C_GREEN}已安装 / 有运行中的规则${C_RESET}"
    else
      echo -e " 当前状态: ${C_GREEN}已安装 / 未运行${C_RESET}"
    fi
  else
    echo -e " 当前状态: ${C_RED}未安装${C_RESET}"
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
    read -rp " 请选择 [0-3]: " s
    case "$s" in
      1) add_single_rule; pause ;;
      2) add_batch_rules; pause ;;
      3) delete_rules; pause ;;
      0) break ;;
      *) red "无效选项"; sleep 1 ;;
    esac
  done
}

# ------------------ 主入口 ------------------
main(){
  require_root
  init_env

  # 隐藏模式：仅运行 DDNS 监控循环（由 ddns_monitor_start 调用）
  if [[ "$1" == "--ddns-monitor" ]]; then
    ddns_monitor_loop
    exit 0
  fi

  self_install_menu

  while true; do
    show_menu
    read -r num
    case "$num" in
      0) upgrade_brook; pause ;;
      1) install_brook; pause ;;
      2) update_brook; pause ;;
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
