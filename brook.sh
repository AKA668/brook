#!/usr/bin/env bash
# =========================================================
# Brook 一键管理脚本（菜单版 + 自动 DDNS 更新 + 支持新版 core -t）
# 作者：AKA668（逻辑整理 & 优化 by ChatGPT）
# =========================================================

set -e

# ------------------ 全局变量 ------------------
BROOK_CORE="/usr/local/bin/brook_core"
BROOK_MENU="/usr/local/bin/brook"
RULE_FILE="/etc/brook_rules.conf"
LOG_DIR="/var/log/brook"
PID_DIR="/var/run"
DDNS_CACHE_DIR="/var/run/brook_ddns"
DDNS_INTERVAL=10

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
    red "❌ 请使用 root 用户运行（sudo -i）"
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
    *) echo "" ;;
  esac
}

download_brook_core(){
  local file url tmp
  file=$(detect_arch)
  [[ -z "$file" ]] && { red "❌ 不支持架构 $(uname -m)"; exit 1; }

  url="https://github.com/txthinking/brook/releases/latest/download/${file}"

  yellow "▶ 正在下载 Brook 官方核心：$file"
  tmp=$(mktemp)

  if command -v curl >/dev/null; then
    curl -L -o "$tmp" "$url"
  else
    wget -O "$tmp" "$url"
  fi

  mv "$tmp" "$BROOK_CORE"
  chmod +x "$BROOK_CORE"
  green "✔ Brook 核心安装成功：$BROOK_CORE"
}

is_core_installed(){ [[ -x "$BROOK_CORE" ]]; }

install_brook(){ download_brook_core; }
upgrade_brook(){ download_brook_core; }
update_brook(){ download_brook_core; }

uninstall_brook(){
  if is_core_installed; then
    read -rp "确认卸载 Brook 核心？[y/N]：" c
    [[ "$c" =~ ^[yY]$ ]] && rm -f "$BROOK_CORE" && green "✔ 已卸载 Brook 核心"
  fi

  read -rp "是否清空转发规则？[y/N]：" c2
  if [[ "$c2" =~ ^[yY]$ ]]; then
    rm -f "$RULE_FILE"
    touch "$RULE_FILE"
    green "✔ 已清空规则"
  fi
}

# ------------------ 规则管理 ------------------
next_rule_id(){
  if [[ ! -s "$RULE_FILE" ]]; then echo 1; return; fi
  awk -F'|' '{if($1+0>max)max=$1}END{print max+1}' "$RULE_FILE"
}

print_rules(){
  if [[ ! -s "$RULE_FILE" ]]; then yellow "暂无规则"; return; fi

  printf "\n%-4s %-10s %-25s %-10s %-s\n" "ID" "本地端口" "目标主机" "目标端口" "备注"
  printf "%-4s %-10s %-25s %-10s %-s\n" "----" "--------" "------------------------" "----------" "--------"

  while IFS='|' read -r id lp host rp remark; do
    [[ -z "$id" ]] && continue
    printf "%-4s %-10s %-25s %-10s %-s\n" "$id" "$lp" "$host" "$rp" "$remark"
  done < "$RULE_FILE"
  echo
}

add_single_rule(){
  yellow "▶ 添加单条规则"
  read -rp "本地端口: " lp
  read -rp "目标主机(域名/IP): " host
  read -rp "目标端口: " rp
  read -rp "备注: " remark

  [[ -z "$lp" || -z "$host" || -z "$rp" ]] && { red "❌ 参数不完整"; return; }

  id=$(next_rule_id)
  echo "$id|$lp|$host|$rp|$remark" >> "$RULE_FILE"
  green "✔ 添加规则成功 ID=$id"
}

add_batch_rules(){
  yellow "▶ 批量添加（空行结束）"
  echo "格式: 本地端口 目标主机 目标端口 备注"

  while true; do
    read -rp "> " line
    [[ -z "$line" ]] && break
    lp=$(echo "$line"|awk '{print $1}')
    host=$(echo "$line"|awk '{print $2}')
    rp=$(echo "$line"|awk '{print $3}')
    remark=$(echo "$line"|cut -d ' ' -f4-)

    id=$(next_rule_id)
    echo "$id|$lp|$host|$rp|$remark" >> "$RULE_FILE"
    green "✔ 添加规则 ID=$id"
  done
}

delete_rules(){
  print_rules
  read -rp "输入要删除的 ID (空格分隔): " ids
  [[ -z "$ids" ]] && return

  for id in $ids; do stop_rule "$id"; done

  tmp=$(mktemp)
  while IFS='|' read -r id lp host rp remark; do
    skip=0
    for del in $ids; do [[ "$id" == "$del" ]] && skip=1; done
    [[ $skip -eq 1 ]] && continue
    echo "$id|$lp|$host|$rp|$remark" >> "$tmp"
  done < "$RULE_FILE"

  mv "$tmp" "$RULE_FILE"
  green "✔ 删除成功"
}

# ------------------ DNS工具 ------------------
resolve_host_realtime(){
  host="$1"

  # IP 直接返回
  if [[ "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then echo "$host"; return; fi

  if command -v getent >/dev/null; then
    getent hosts "$host" | awk '{print $1}' | head -n1 && return
  fi

  if command -v dig >/dev/null; then
    dig +short "$host" | grep -E '^[0-9.]+' | head -n1 && return
  fi

  ping -c1 -W1 "$host" 2>/dev/null | awk -F'[()]' '/PING/{print $2}'
}

# ------------------ 启动单条规则（新版 -t） ------------------
start_rule(){
  id="$1"; lp="$2"; host="$3"; rp="$4"; ip_override="$5"

  pid_file="$PID_DIR/brook_${id}.pid"
  log_file="$LOG_DIR/${id}.log"

  # 已启动则跳过
  if [[ -f "$pid_file" ]]; then
    pid=$(cat "$pid_file")
    if [[ -n "$pid" && -d "/proc/$pid" ]]; then
      yellow "规则 $id 已运行 (PID $pid)"
      return
    fi
  fi

  ip="${ip_override:-$(resolve_host_realtime "$host")}"
  [[ -z "$ip" ]] && ip="解析失败"
  echo "$ip" > "$DDNS_CACHE_DIR/$id.ip"

  nohup "$BROOK_CORE" relay -l ":$lp" -t "${ip}:$rp" >>"$log_file" 2>&1 &
  echo $! > "$pid_file"

  green "✔ 启动规则 $id：:$lp → $host($ip):$rp"
}

# ------------------ 停止规则 ------------------
stop_rule(){
  id="$1"
  pid_file="$PID_DIR/brook_${id}.pid"

  [[ ! -f "$pid_file" ]] && return
  pid=$(cat "$pid_file")

  kill "$pid" 2>/dev/null || true
  sleep 0.2
  [[ -d "/proc/$pid" ]] && kill -9 "$pid"

  rm -f "$pid_file"
  green "✔ 停止规则 $id"
}

# ------------------ 启动/停止所有规则 ------------------
start_all(){
  ! is_core_installed && { red "❌ 请先安装核心"; return; }
  [[ ! -s "$RULE_FILE" ]] && { yellow "暂无规则"; return; }

  while IFS='|' read -r id lp host rp remark; do
    start_rule "$id" "$lp" "$host" "$rp"
  done < "$RULE_FILE"

  ddns_monitor_start
}

stop_all(){
  for f in "$PID_DIR"/brook_*.pid; do
    [[ -f "$f" ]] || break
    id=$(basename "$f"|sed 's/brook_//'|sed 's/.pid//')
    stop_rule "$id"
  done
  ddns_monitor_stop
}

# ------------------ 状态 ------------------
status_all(){
  [[ ! -s "$RULE_FILE" ]] && { yellow "暂无规则"; return; }

  printf "\n%-4s %-10s %-10s %-25s %-10s %-s\n" "ID" "本地端口" "状态" "目标主机" "目标端口" "备注"
  printf "%-4s %-10s %-10s %-25s %-10s %-s\n" "----" "--------" "--------" "------------------------" "----------" "--------"

  while IFS='|' read -r id lp host rp remark; do
    pid_file="$PID_DIR/brook_${id}.pid"
    status="stopped"
    if [[ -f "$pid_file" ]]; then
      pid=$(cat "$pid_file")
      [[ -d "/proc/$pid" ]] && status="running($pid)"
    fi
    printf "%-4s %-10s %-10s %-25s %-10s %-s\n" "$id" "$lp" "$status" "$host" "$rp" "$remark"
  done < "$RULE_FILE"
}

# ------------------ 日志 ------------------
view_logs(){
  print_rules
  read -rp "查看日志的 ID：" id
  log="$LOG_DIR/$id.log"
  [[ ! -f "$log" ]] && { yellow "无日志"; return; }

  yellow "▶ Ctrl + C 退出"
  tail -f "$log"
}

# ------------------ 查看 DDNS 最新解析 ------------------
show_ddns_ips(){
  printf "\n%-4s %-25s %-20s %-s\n" "ID" "主机" "当前解析IP" "备注"
  printf "%-4s %-25s %-20s %-s\n" "----" "------------------------" "--------------------" "--------"

  while IFS='|' read -r id lp host rp remark; do
    ip=$(resolve_host_realtime "$host")
    [[ -z "$ip" ]] && ip="解析失败"
    printf "%-4s %-25s %-20s %-s\n" "$id" "$host" "$ip" "$remark"
  done < "$RULE_FILE"
}

# ------------------ DDNS 自动监控 ------------------
ddns_monitor_loop(){
  log="$LOG_DIR/ddns.log"
  echo "DDNS 监控已启动" > "$log"

  while true; do
    [[ ! -s "$RULE_FILE" ]] && { sleep $DDNS_INTERVAL; continue; }

    while IFS='|' read -r id lp host rp remark; do
      new_ip=$(resolve_host_realtime "$host")
      cache="$DDNS_CACHE_DIR/$id.ip"
      old_ip=$(cat "$cache" 2>/dev/null || echo "")

      if [[ "$new_ip" != "$old_ip" && "$new_ip" != "解析失败" ]]; then
        echo "$(date '+%F %T') IP变化 $old_ip → $new_ip" >> "$log"
        stop_rule "$id"
        start_rule "$id" "$lp" "$host" "$rp" "$new_ip"
      fi

    done < "$RULE_FILE"
    sleep "$DDNS_INTERVAL"
  done
}

ddns_monitor_start(){
  if [[ -f /var/run/brook_ddns.pid ]]; then
    pid=$(cat /var/run/brook_ddns.pid)
    [[ -d "/proc/$pid" ]] && { yellow "DDNS 已运行"; return; }
    rm -f /var/run/brook_ddns.pid
  fi

  nohup "$BROOK_MENU" --ddns-monitor >/dev/null 2>&1 &
  echo $! >/var/run/brook_ddns.pid
  green "✔ DDNS 自动更新已启动"
}

ddns_monitor_stop(){
  if [[ -f /var/run/brook_ddns.pid ]]; then
    pid=$(cat /var/run/brook_ddns.pid)
    kill "$pid" 2>/dev/null || true
    sleep 0.2
    [[ -d "/proc/$pid" ]] && kill -9 "$pid"
    rm -f /var/run/brook_ddns.pid
    green "✔ DDNS 自动更新已停止"
  fi
}

# ------------------ 安装自身为 brook 命令（优化版） ------------------
self_install_menu(){
  self_path=$(readlink -f "$0")
  bro_path=$(readlink -f "$BROOK_MENU")

  if [[ "$self_path" != "$bro_path" ]]; then
    cp "$self_path" "$BROOK_MENU"
    chmod +x "$BROOK_MENU"
    green "✔ 已安装为命令：brook"
  fi
}

# ------------------ 菜单 ------------------
show_menu(){
  clear
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  0. 升级 Brook 核心"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  1. 安装 Brook"
  echo "  2. 更新 Brook"
  echo "  3. 卸载 Brook"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  4. 启动 Brook"
  echo "  5. 停止 Brook"
  echo "  6. 重启 Brook"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  7. 设置 端口转发（可批量）"
  echo "  8. 查看 端口转发"
  echo "  9. 查看 日志"
  echo " 10. 查看 DDNS 最新 IP"
  echo " 11. 查看 运行状态"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  if is_core_installed; then
    running=$(ls "$PID_DIR"/brook_*.pid 2>/dev/null | wc -l)
    [[ "$running" -gt 0 ]] && echo -e " 当前状态：${C_GREEN}已安装 / 有运行规则${C_RESET}" \
                           || echo -e " 当前状态：${C_GREEN}已安装 / 未运行${C_RESET}"
  else
    echo -e " 当前状态：${C_RED}未安装${C_RESET}"
  fi

  echo
  echo -n " 请输入数字 [0-11]: "
}

menu_forward(){
  while true; do
    clear
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  7. 转发管理"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  1. 添加单条规则"
    echo "  2. 批量添加规则"
    echo "  3. 批量删除规则"
    echo "  0. 返回主菜单"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    read -rp "选择: " s
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

  # 隐藏模式：DDNS 守护
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
