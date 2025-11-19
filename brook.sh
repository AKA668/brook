#!/usr/bin/env bash
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin
export PATH

#=================================================
#  System Required: CentOS/Debian/Ubuntu
#  Description: Brook Port Forward Manager (Official core)
#  Version: 2.0.0
#=================================================

sh_ver="2.0.0"

# 基本路径配置
brook_dir="/usr/local/brook-pf"
brook_file="${brook_dir}/brook"               # 官方 brook 核心
brook_conf="${brook_dir}/brook.conf"          # 配置：port|host|rport|enabled|remark
brook_log="${brook_dir}/brook.log"
ddns_cache_dir="${brook_dir}/ddns_cache"
Crontab_file="/usr/bin/crontab"

# 颜色
Green_font_prefix="\033[32m"
Red_font_prefix="\033[31m"
Yellow_font_prefix="\033[33m"
Green_background_prefix="\033[42;37m"
Red_background_prefix="\033[41;37m"
Font_color_suffix="\033[0m"

Info="${Green_font_prefix}[信息]${Font_color_suffix}"
Error="${Red_font_prefix}[错误]${Font_color_suffix}"
Tip="${Yellow_font_prefix}[提示]${Font_color_suffix}"

#=================================================
# 公共函数
#=================================================

check_root() {
  [[ $EUID != 0 ]] && echo -e "${Error} 当前非 ROOT 账号，无法继续操作，请先切换 root（如：sudo -i）。" && exit 1
}

check_sys() {
  if [[ -f /etc/redhat-release ]]; then
    release="centos"
  elif grep -Eqi "debian" /etc/issue /proc/version; then
    release="debian"
  elif grep -Eqi "ubuntu" /etc/issue /proc/version; then
    release="ubuntu"
  elif grep -Eqi "centos|red hat|redhat" /etc/issue /proc/version; then
    release="centos"
  else
    release="unknown"
  fi
  bit=$(uname -m)
}

check_installed_status() {
  [[ ! -e ${brook_file} ]] && echo -e "${Error} Brook 核心未安装，请先安装！" && exit 1
}

check_crontab_installed_status() {
  if [[ ! -e ${Crontab_file} ]]; then
    echo -e "${Error} Crontab 未安装，开始安装..."
    if [[ ${release} == "centos" ]]; then
      yum install -y cronie >/dev/null 2>&1 || yum install -y crond >/dev/null 2>&1
      systemctl enable crond >/dev/null 2>&1 || service crond start >/dev/null 2>&1
    else
      apt-get update >/dev/null 2>&1
      apt-get install -y cron >/dev/null 2>&1
      systemctl enable cron >/dev/null 2>&1 || service cron start >/dev/null 2>&1
    fi
    if [[ ! -e ${Crontab_file} ]]; then
      echo -e "${Error} Crontab 安装失败，请检查！" && exit 1
    else
      echo -e "${Info} Crontab 安装成功。"
    fi
  fi
}

init_env() {
  mkdir -p "${brook_dir}" "${ddns_cache_dir}"
  [[ ! -e "${brook_conf}" ]] && touch "${brook_conf}"
  [[ ! -e "${brook_log}" ]] && touch "${brook_log}"
}

#=================================================
# Brook 核心 下载 / 更新
#=================================================

detect_arch() {
  case "${bit}" in
    x86_64|amd64) echo "brook_linux_amd64" ;;
    i386|i686) echo "brook_linux_386" ;;
    armv7l|armv7) echo "brook_linux_arm7" ;;
    armv6l|armv6) echo "brook_linux_arm6" ;;
    aarch64|arm64) echo "brook_linux_arm64" ;;
    mips) echo "brook_linux_mips" ;;
    mipsle) echo "brook_linux_mipsle" ;;
    mips64) echo "brook_linux_mips64" ;;
    mips64le) echo "brook_linux_mips64le" ;;
    *) echo "" ;;
  esac
}

check_new_ver() {
  echo -e "请输入要下载安装的 Brook 版本号（tag），例如：${Green_font_prefix}v20250101${Font_color_suffix}"
  echo -e "直接回车自动获取官方最新版本。"
  read -e -p "版本号: " brook_new_ver
  if [[ -z ${brook_new_ver} ]]; then
    brook_new_ver=$(curl -s https://api.github.com/repos/txthinking/brook/releases/latest | grep '"tag_name"' | head -n1 | awk -F '"' '{print $4}')
    [[ -z ${brook_new_ver} ]] && echo -e "${Error} 获取 Brook 最新版本失败，请检查网络！" && exit 1
    echo -e "${Info} 检测到 Brook 最新版本为 ${Green_font_prefix}${brook_new_ver}${Font_color_suffix}"
  else
    echo -e "${Info} 将安装指定版本：${Green_font_prefix}${brook_new_ver}${Font_color_suffix}"
  fi
}

Download_brook() {
  local arch file url tmp
  arch=$(detect_arch)
  [[ -z "${arch}" ]] && echo -e "${Error} 不支持的系统架构：${bit}" && exit 1

  [[ ! -d "${brook_dir}" ]] && mkdir -p "${brook_dir}"
  cd "${brook_dir}" || exit 1

  file="${arch}"
  url="https://github.com/txthinking/brook/releases/download/${brook_new_ver}/${file}"
  echo -e "${Info} 开始下载 Brook 官方核心：${url}"

  tmp=$(mktemp)
  if command -v curl >/dev/null 2>&1; then
    curl -L -o "${tmp}" "${url}"
  else
    wget --no-check-certificate -O "${tmp}" "${url}"
  fi

  mv "${tmp}" "${brook_file}"
  chmod +x "${brook_file}"

  [[ ! -x "${brook_file}" ]] && echo -e "${Error} Brook 核心下载失败！" && exit 1
  echo -e "${Info} Brook 核心已安装：${Green_font_prefix}${brook_file}${Font_color_suffix}"
}

check_ver_comparison() {
  check_installed_status
  brook_now_ver=$("${brook_file}" -v 2>/dev/null | awk '{print $2}')
  [[ -z ${brook_now_ver} ]] && echo -e "${Error} 获取当前 Brook 版本失败！" && exit 1
  brook_now_ver="v${brook_now_ver}"
  if [[ "${brook_now_ver}" != "${brook_new_ver}" ]]; then
    echo -e "${Info} 发现新版本：${Green_font_prefix}${brook_new_ver}${Font_color_suffix}，当前版本：${Red_font_prefix}${brook_now_ver}${Font_color_suffix}"
    read -e -p "是否更新？[Y/n]：" yn
    [[ -z "${yn}" ]] && yn="y"
    if [[ "${yn}" == [Yy] ]]; then
      stop_all_relays_silent
      Download_brook
      echo -e "${Info} Brook 核心已更新，建议执行 [重启 Brook]。"
    else
      echo -e "${Info} 已取消更新。"
    fi
  else
    echo -e "${Info} 当前已是最新版本：${Green_font_prefix}${brook_now_ver}${Font_color_suffix}"
  fi
}

Install_brook() {
  check_root
  if [[ -e ${brook_file} ]]; then
    echo -e "${Error} 检测到 Brook 已安装！" && exit 1
  fi
  echo -e "${Info} 初始化环境..."
  init_env
  echo -e "${Info} 检测最新版本..."
  check_new_ver
  echo -e "${Info} 开始下载 / 安装 Brook 核心..."
  Download_brook
  echo -e "${Info} Brook 安装完成。请通过 [7. 设置 Brook 端口转发] 添加规则。"
}

Update_brook() {
  check_root
  check_installed_status
  init_env
  echo -e "${Info} 检测最新版本..."
  check_new_ver
  check_ver_comparison
}

Uninstall_brook() {
  check_root
  check_installed_status
  echo -e "确定要卸载 Brook 及其转发配置？[y/N]"
  read -e -p "(默认: n): " unyn
  [[ -z ${unyn} ]] && unyn="n"
  if [[ ${unyn} == [Yy] ]]; then
    stop_all_relays_silent
    # 清理 iptables
    if [[ -s "${brook_conf}" ]]; then
      while IFS='|' read -r port host rport enabled remark; do
        [[ -z "${port}" ]] && continue
        iptables -D INPUT -m state --state NEW -m tcp -p tcp --dport "${port}" -j ACCEPT 2>/dev/null || true
        iptables -D INPUT -m state --state NEW -m udp -p udp --dport "${port}" -j ACCEPT 2>/dev/null || true
      done < "${brook_conf}"
      Save_iptables
    fi
    # 删除监控 crontab
    if crontab -l 2>/dev/null | grep -q "brook.sh monitor"; then
      crontab_monitor_brook_cron_stop
    fi
    rm -rf "${brook_dir}"
    echo -e "${Info} Brook 卸载完成。"
  else
    echo -e "${Info} 已取消卸载。"
  fi
}

#=================================================
# 配置文件 & 端口转发管理
# 配置格式：port|host|remote_port|enabled(0/1)|remark
#=================================================

Read_config() {
  [[ ! -e ${brook_conf} ]] && echo -e "${Error} Brook 配置文件不存在！" && exit 1
  user_all=$(grep -Ev '^\s*$' "${brook_conf}" || true)
  user_all_num=$(echo "${user_all}" | wc -l)
}

check_port_exists() {
  local check_port="$1"
  [[ -z "${check_port}" ]] && return 1
  if grep -Eq "^${check_port}\|" "${brook_conf}"; then
    return 0
  else
    return 1
  fi
}

list_port() {
  Read_config
  if [[ -z "${user_all}" ]]; then
    echo -e "${Info} 当前没有任何端口转发配置。"
    return
  fi

  echo -e "================ 转发规则列表 ================"
  printf "%-8s %-20s %-8s %-6s %-s\n" "端口" "目标主机" "目标端口" "状态" "备注"
  echo "----------------------------------------------------"
  echo "${user_all}" | while IFS='|' read -r port host rport enabled remark; do
    [[ -z "${port}" ]] && continue
    if [[ "${enabled}" == "1" ]]; then
      status="${Green_font_prefix}启用${Font_color_suffix}"
    else
      status="${Red_font_prefix}禁用${Font_color_suffix}"
    fi
    printf "%-8s %-20s %-8s %-6b %-s\n" "${port}" "${host}" "${rport}" "${status}" "${remark}"
  done
  echo "================================================"
}

Set_pf_Enabled() {
  echo -e "是否启用该端口转发？[Y/n]"
  read -e -p "(默认: Y 启用): " pf_Enabled_un
  [[ -z ${pf_Enabled_un} ]] && pf_Enabled_un="y"
  if [[ ${pf_Enabled_un} == [Yy] ]]; then
    bk_Enabled="1"
  else
    bk_Enabled="0"
  fi
}

Set_port() {
  while true; do
    echo -e "请输入本地监听端口 [1-65535]"
    read -e -p "(默认取消): " bk_port
    [[ -z "${bk_port}" ]] && echo "已取消。" && return 1
    echo $((bk_port + 0)) &>/dev/null || { echo "请输入数字端口。"; continue; }
    if [[ ${bk_port} -ge 1 && ${bk_port} -le 65535 ]]; then
      echo -e "本地端口：${Green_background_prefix} ${bk_port} ${Font_color_suffix}"
      return 0
    else
      echo "端口范围应为 1-65535。"
    fi
  done
}

Set_IP_pf() {
  echo "请输入被转发的 IP 或域名："
  read -e -p "(默认取消): " bk_ip_pf
  [[ -z "${bk_ip_pf}" ]] && echo "已取消。" && return 1
  echo -e "被转发目标：${Green_background_prefix} ${bk_ip_pf} ${Font_color_suffix}"
  return 0
}

Set_port_pf() {
  while true; do
    echo -e "请输入被转发的远程端口 [1-65535]"
    read -e -p "(默认取消): " bk_port_pf
    [[ -z "${bk_port_pf}" ]] && echo "已取消。" && return 1
    echo $((bk_port_pf + 0)) &>/dev/null || { echo "请输入数字端口。"; continue; }
    if [[ ${bk_port_pf} -ge 1 && ${bk_port_pf} -le 65535 ]]; then
      echo -e "被转发端口：${Green_background_prefix} ${bk_port_pf} ${Font_color_suffix}"
      return 0
    else
      echo "端口范围应为 1-65535。"
    fi
  done
}

Set_remark() {
  read -e -p "请输入备注（可空）: " bk_remark
}

Add_pf_single() {
  Read_config
  while true; do
    Set_port || return
    check_port_exists "${bk_port}" && echo -e "${Error} 该本地监听端口已存在 [${bk_port}]！" && return
    Set_IP_pf || return
    Set_port_pf || return
    Set_pf_Enabled
    Set_remark
    echo "${bk_port}|${bk_ip_pf}|${bk_port_pf}|${bk_Enabled}|${bk_remark}" >> "${brook_conf}"
    echo -e "${Info} 已添加端口转发：${Green_font_prefix}${bk_port} -> ${bk_ip_pf}:${bk_port_pf}${Font_color_suffix}"
    Add_iptables "${bk_port}"
    Save_iptables
    read -e -p "继续添加？[Y/n]：" addyn
    [[ -z ${addyn} ]] && addyn="y"
    [[ ${addyn} == [Yy] ]] || break
  done
}

Add_pf_batch() {
  Read_config
  echo -e "${Info} 批量添加端口转发，格式：本地端口 目标IP(或域名) 目标端口 启用(0/1) 备注(可含空格)"
  echo -e "示例：16929 ge1.kuailianba.top 12312 1 某机场专线"
  echo -e "空行回车结束输入。"
  while true; do
    read -e -p "> " line
    [[ -z "${line}" ]] && break
    bk_port=$(echo "${line}" | awk '{print $1}')
    bk_ip_pf=$(echo "${line}" | awk '{print $2}')
    bk_port_pf=$(echo "${line}" | awk '{print $3}')
    bk_Enabled=$(echo "${line}" | awk '{print $4}')
    bk_remark=$(echo "${line}" | cut -d ' ' -f5-)
    [[ -z "${bk_port}" || -z "${bk_ip_pf}" || -z "${bk_port_pf}" ]] && { echo -e "${Error} 参数不足，已跳过。"; continue; }
    [[ -z "${bk_Enabled}" ]] && bk_Enabled="1"
    check_port_exists "${bk_port}" && { echo -e "${Error} 端口 ${bk_port} 已存在，跳过。"; continue; }
    echo "${bk_port}|${bk_ip_pf}|${bk_port_pf}|${bk_Enabled}|${bk_remark}" >> "${brook_conf}"
    Add_iptables "${bk_port}"
    echo -e "${Info} 已添加：${bk_port} -> ${bk_ip_pf}:${bk_port_pf} 状态=${bk_Enabled} 备注=${bk_remark}"
  done
  Save_iptables
}

Del_pf_single() {
  Read_config
  list_port
  Set_port || return
  check_port_exists "${bk_port}" || { echo -e "${Error} 该端口不存在 [${bk_port}]！"; return; }
  sed -i "/^${bk_port}\|/d" "${brook_conf}"
  Del_iptables "${bk_port}"
  Save_iptables
  stop_relay_by_port "${bk_port}"
  echo -e "${Info} 已删除端口转发 [${bk_port}]。"
}

Del_pf_batch() {
  Read_config
  list_port
  echo -e "请输入要批量删除的端口（空格分隔）："
  read -e -p "> " ports
  [[ -z "${ports}" ]] && echo "已取消。" && return
  for p in ${ports}; do
    if grep -Eq "^${p}\|" "${brook_conf}"; then
      sed -i "/^${p}\|/d" "${brook_conf}"
      Del_iptables "${p}"
      stop_relay_by_port "${p}"
      echo -e "${Info} 已删除端口：${p}"
    else
      echo -e "${Error} 端口 ${p} 不存在，跳过。"
    fi
  done
  Save_iptables
}

Modify_pf() {
  Read_config
  list_port
  echo -e "请输入要修改的本地端口："
  read -e -p "> " bk_port_Modify
  check_port_exists "${bk_port_Modify}" || { echo -e "${Error} 该端口不存在！"; return; }
  old_line=$(grep "^${bk_port_Modify}|" "${brook_conf}")
  old_host=$(echo "${old_line}" | awk -F'|' '{print $2}')
  old_rport=$(echo "${old_line}" | awk -F'|' '{print $3}')
  old_enabled=$(echo "${old_line}" | awk -F'|' '{print $4}')
  old_remark=$(echo "${old_line}" | awk -F'|' '{print $5}')

  echo -e "当前配置：端口=${bk_port_Modify} host=${old_host} rport=${old_rport} 启用=${old_enabled} 备注=${old_remark}"

  Set_port || return
  if [[ "${bk_port}" != "${bk_port_Modify}" ]] && check_port_exists "${bk_port}"; then
    echo -e "${Error} 新端口 ${bk_port} 已存在！" && return
  fi
  Set_IP_pf || return
  Set_port_pf || return
  Set_pf_Enabled
  Set_remark

  sed -i "/^${bk_port_Modify}\|/d" "${brook_conf}"
  echo "${bk_port}|${bk_ip_pf}|${bk_port_pf}|${bk_Enabled}|${bk_remark}" >> "${brook_conf}"

  Del_iptables "${bk_port_Modify}"
  Add_iptables "${bk_port}"
  Save_iptables

  stop_relay_by_port "${bk_port_Modify}"
  echo -e "${Info} 端口转发已修改。"
}

Modify_Enabled_pf() {
  Read_config
  list_port
  Set_port || return
  check_port_exists "${bk_port}" || { echo -e "${Error} 该端口不存在！"; return; }
  line=$(grep "^${bk_port}|" "${brook_conf}")
  host=$(echo "${line}" | awk -F'|' '{print $2}')
  rport=$(echo "${line}" | awk -F'|' '{print $3}')
  enabled=$(echo "${line}" | awk -F'|' '{print $4}')
  remark=$(echo "${line}" | awk -F'|' '{print $5}')

  if [[ "${enabled}" == "1" ]]; then
    echo -e "当前状态：${Green_font_prefix}启用${Font_color_suffix}，是否改为${Red_font_prefix}禁用${Font_color_suffix}？[Y/n]"
    read -e -p "(默认: Y 禁用): " ans
    [[ -z "${ans}" ]] && ans="y"
    if [[ "${ans}" == [Yy] ]]; then
      enabled_new="0"
      sed -i "/^${bk_port}\|/d" "${brook_conf}"
      echo "${bk_port}|${host}|${rport}|${enabled_new}|${remark}" >> "${brook_conf}"
      stop_relay_by_port "${bk_port}"
      echo -e "${Info} 已禁用端口转发 ${bk_port}。"
    else
      echo "已取消。"
    fi
  else
    echo -e "当前状态：${Red_font_prefix}禁用${Font_color_suffix}，是否改为${Green_font_prefix}启用${Font_color_suffix}？[Y/n]"
    read -e -p "(默认: Y 启用): " ans
    [[ -z "${ans}" ]] && ans="y"
    if [[ "${ans}" == [Yy] ]]; then
      enabled_new="1"
      sed -i "/^${bk_port}\|/d" "${brook_conf}"
      echo "${bk_port}|${host}|${rport}|${enabled_new}|${remark}" >> "${brook_conf}"
      echo -e "${Info} 已启用端口转发 ${bk_port}，可通过 [启动 Brook] 生效。"
    else
      echo "已取消。"
    fi
  fi
}

Set_brook() {
  check_installed_status
  init_env
  echo && echo -e "你要做什么？
 ${Green_font_prefix}1.${Font_color_suffix}  添加单条转发
 ${Green_font_prefix}2.${Font_color_suffix}  删除单条转发
 ${Green_font_prefix}3.${Font_color_suffix}  修改转发
 ${Green_font_prefix}4.${Font_color_suffix}  启用/禁用转发
 ${Green_font_prefix}5.${Font_color_suffix}  批量添加转发
 ${Green_font_prefix}6.${Font_color_suffix}  批量删除转发
"
  read -e -p "(默认取消): " bk_modify
  [[ -z "${bk_modify}" ]] && echo "已取消。" && return
  case "${bk_modify}" in
    1) Add_pf_single ;;
    2) Del_pf_single ;;
    3) Modify_pf ;;
    4) Modify_Enabled_pf ;;
    5) Add_pf_batch ;;
    6) Del_pf_batch ;;
    *) echo -e "${Error} 请输入正确的数字（1-6）" ;;
  esac
}

#=================================================
# iptables
#=================================================

Add_iptables() {
  local port="$1"
  [[ -z "${port}" ]] && return
  iptables -I INPUT -m state --state NEW -m tcp -p tcp --dport "${port}" -j ACCEPT 2>/dev/null || true
  iptables -I INPUT -m state --state NEW -m udp -p udp --dport "${port}" -j ACCEPT 2>/dev/null || true
}

Del_iptables() {
  local port="$1"
  [[ -z "${port}" ]] && return
  iptables -D INPUT -m state --state NEW -m tcp -p tcp --dport "${port}" -j ACCEPT 2>/dev/null || true
  iptables -D INPUT -m state --state NEW -m udp -p udp --dport "${port}" -j ACCEPT 2>/dev/null || true
}

Save_iptables() {
  if [[ ${release} == "centos" ]]; then
    service iptables save 2>/dev/null || echo -e "${Tip} iptables 配置保存失败（可能未安装 iptables-services）。"
  else
    iptables-save > /etc/iptables.up.rules 2>/dev/null || true
  fi
}

Set_iptables() {
  if [[ ${release} == "centos" ]]; then
    service iptables save 2>/dev/null || true
    chkconfig --level 2345 iptables on 2>/dev/null || true
  else
    iptables-save > /etc/iptables.up.rules 2>/dev/null || true
    echo -e '#!/bin/bash\n/sbin/iptables-restore < /etc/iptables.up.rules' > /etc/network/if-pre-up.d/iptables
    chmod +x /etc/network/if-pre-up.d/iptables
  fi
}

#=================================================
# Brook 进程管理 & DDNS 监控
#=================================================

resolve_ip() {
  local host="$1"
  [[ -z "${host}" ]] && return
  if [[ "${host}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "${host}"
    return
  fi
  # 尝试多种解析方式
  if command -v getent >/dev/null 2>&1; then
    getent hosts "${host}" | awk '{print $1}' | head -n1 && return
  fi
  if command -v dig >/dev/null 2>&1; then
    dig +short "${host}" | grep -E '^[0-9.]+' | head -n1 && return
  fi
  ping -c1 -W1 "${host}" 2>/dev/null | awk -F'[()]' '/PING/{print $2}' | head -n1
}

pid_file_for_port() {
  local port="$1"
  echo "/var/run/brook_pf_${port}.pid"
}

start_relay_for_rule() {
  local port="$1" host="$2" rport="$3"
  check_installed_status
  [[ -z "${port}" || -z "${host}" || -z "${rport}" ]] && return
  local ip
  ip=$(resolve_ip "${host}")
  [[ -z "${ip}" ]] && { echo -e "${Error} 解析 ${host} 失败，跳过启动 [${port}]。"; return; }

  local pidf logf
  pidf=$(pid_file_for_port "${port}")
  logf="${brook_log}"

  # 已有旧进程则杀掉
  if [[ -f "${pidf}" ]]; then
    oldpid=$(cat "${pidf}")
    [[ -n "${oldpid}" && -d "/proc/${oldpid}" ]] && kill "${oldpid}" 2>/dev/null || true
  fi

  nohup "${brook_file}" relay -l ":${port}" -t "${ip}:${rport}" >> "${logf}" 2>&1 &
  echo $! > "${pidf}"
  echo "${ip}" > "${ddns_cache_dir}/${port}.ip"
  echo -e "${Info} 启动转发：${Green_font_prefix}:${port}${Font_color_suffix} → ${host}(${ip}):${rport}"
}

stop_relay_by_port() {
  local port="$1"
  local pidf
  pidf=$(pid_file_for_port "${port}")
  [[ ! -f "${pidf}" ]] && return
  local pid
  pid=$(cat "${pidf}")
  kill "${pid}" 2>/dev/null || true
  sleep 0.2
  [[ -d "/proc/${pid}" ]] && kill -9 "${pid}" 2>/dev/null || true
  rm -f "${pidf}"
}

start_all_relays() {
  check_installed_status
  Read_config
  if [[ -z "${user_all}" ]]; then
    echo -e "${Error} 没有任何规则，无法启动。"
    return
  fi
  echo -e "${Info} 开始启动所有启用的端口转发规则..."
  echo "${user_all}" | while IFS='|' read -r port host rport enabled remark; do
    [[ -z "${port}" ]] && continue
    [[ "${enabled}" != "1" ]] && continue
    start_relay_for_rule "${port}" "${host}" "${rport}"
  done
  echo -e "${Info} 所有规则启动命令已发送。"
}

stop_all_relays_silent() {
  Read_config
  [[ -z "${user_all}" ]] && return
  echo "${user_all}" | while IFS='|' read -r port host rport enabled remark; do
    [[ -z "${port}" ]] && continue
    stop_relay_by_port "${port}"
  done
}

stop_all_relays() {
  Read_config
  if [[ -z "${user_all}" ]]; then
    echo -e "${Info} 没有规则。"
    return
  fi
  echo -e "${Info} 停止所有转发规则..."
  stop_all_relays_silent
  echo -e "${Info} 所有转发已停止。"
}

restart_all_relays() {
  stop_all_relays_silent
  start_all_relays
}

View_Log() {
  check_installed_status
  [[ ! -e ${brook_log} ]] && echo -e "${Error} 日志文件不存在：${brook_log}" && return
  echo && echo -e "${Tip} 按 ${Red_font_prefix}Ctrl+C${Font_color_suffix} 结束查看日志。" && echo
  tail -f "${brook_log}"
}

status_all_relays() {
  Read_config
  if [[ -z "${user_all}" ]]; then
    echo -e "${Info} 当前没有规则。"
    return
  fi
  echo -e "================ 运行状态 ================"
  printf "%-8s %-10s %-20s %-8s %-s\n" "端口" "进程" "目标主机" "目标端口" "备注"
  echo "------------------------------------------------------"
  echo "${user_all}" | while IFS='|' read -r port host rport enabled remark; do
    [[ -z "${port}" ]] && continue
    pidf=$(pid_file_for_port "${port}")
    status="stopped"
    if [[ -f "${pidf}" ]]; then
      pid=$(cat "${pidf}")
      [[ -n "${pid}" && -d "/proc/${pid}" ]] && status="running(${pid})"
    fi
    [[ "${enabled}" != "1" ]] && status="${status}/disabled"
    printf "%-8s %-10s %-20s %-8s %-s\n" "${port}" "${status}" "${host}" "${rport}" "${remark}"
  done
  echo "=========================================="
}

# 监控：自动重启 & DDNS 更新
crontab_monitor_brook() {
  check_installed_status
  init_env
  Read_config
  if [[ -z "${user_all}" ]]; then
    echo -e "${Info} 无规则，监控退出。"
    return
  fi
  echo -e "${Info} [$(date '+%F %T')] 开始执行监控任务..." >> "${brook_log}"

  echo "${user_all}" | while IFS='|' read -r port host rport enabled remark; do
    [[ -z "${port}" ]] && continue
    [[ "${enabled}" != "1" ]] && continue

    # 检测进程是否存在
    pidf=$(pid_file_for_port "${port}")
    need_restart=0
    if [[ -f "${pidf}" ]]; then
      pid=$(cat "${pidf}")
      if [[ -z "${pid}" || ! -d "/proc/${pid}" ]]; then
        need_restart=1
      fi
    else
      need_restart=1
    fi

    # 检测 DDNS IP 是否变化
    new_ip=$(resolve_ip "${host}")
    cache_ip_file="${ddns_cache_dir}/${port}.ip"
    old_ip=""
    [[ -f "${cache_ip_file}" ]] && old_ip=$(cat "${cache_ip_file}")
    if [[ -n "${new_ip}" && "${new_ip}" != "${old_ip}" ]]; then
      echo -e "${Info} [$(date '+%F %T')] 规则端口 ${port} 域名 ${host} IP 变化：${old_ip} -> ${new_ip}" >> "${brook_log}"
      need_restart=1
    fi

    if [[ "${need_restart}" -eq 1 ]]; then
      stop_relay_by_port "${port}"
      start_relay_for_rule "${port}" "${host}" "${rport}"
      echo -e "${Info} [$(date '+%F %T')] 已重启规则端口 ${port}。" >> "${brook_log}"
    fi
  done
}

Set_crontab_monitor_brook() {
  check_installed_status
  check_crontab_installed_status
  init_env
  cron_exist=$(crontab -l 2>/dev/null | grep "brook.sh monitor" || true)
  if [[ -z "${cron_exist}" ]]; then
    echo && echo -e "当前监控模式：${Red_font_prefix}未开启${Font_color_suffix}"
    echo -e "确定要开启 Brook 服务端运行状态监控？（每分钟检测 & DDNS 自动更新）[Y/n]"
    read -e -p "(默认: y): " ans
    [[ -z "${ans}" ]] && ans="y"
    if [[ "${ans}" == [Yy] ]]; then
      crontab_monitor_brook_cron_start
    else
      echo "已取消。"
    fi
  else
    echo && echo -e "当前监控模式：${Green_font_prefix}已开启${Font_color_suffix}"
    echo -e "确定要关闭 Brook 服务端运行状态监控？[y/N]"
    read -e -p "(默认: n): " ans
    [[ -z "${ans}" ]] && ans="n"
    if [[ "${ans}" == [Yy] ]]; then
      crontab_monitor_brook_cron_stop
    else
      echo "已取消。"
    fi
  fi
}

get_script_path_for_cron() {
  # 优先使用 /usr/local/brook-pf/brook.sh
  local standard="${brook_dir}/brook.sh"
  if [[ -f "${standard}" ]]; then
    echo "${standard}"
    return
  fi
  # 如果当前脚本是本地文件，复制过去
  if [[ -f "$0" ]]; then
    mkdir -p "${brook_dir}"
    cp "$0" "${standard}"
    chmod +x "${standard}"
    echo "${standard}"
    return
  fi
  # 否则从 GitHub 下载最新脚本
  mkdir -p "${brook_dir}"
  curl -Ls "https://raw.githubusercontent.com/AKA668/brook/main/brook.sh" -o "${standard}"
  chmod +x "${standard}"
  echo "${standard}"
}

crontab_monitor_brook_cron_start() {
  local script_path
  script_path=$(get_script_path_for_cron)
  crontab -l 2>/dev/null | sed '/brook.sh monitor/d' > /tmp/crontab_brook.tmp 2>/dev/null || true
  echo "* * * * * /bin/bash ${script_path} monitor" >> /tmp/crontab_brook.tmp
  crontab /tmp/crontab_brook.tmp
  rm -f /tmp/crontab_brook.tmp
  cron_config=$(crontab -l 2>/dev/null | grep "brook.sh monitor" || true)
  if [[ -z ${cron_config} ]]; then
    echo -e "${Error} 监控任务添加失败！"
  else
    echo -e "${Info} 已开启 Brook 运行状态监控（每分钟）。"
  fi
}

crontab_monitor_brook_cron_stop() {
  crontab -l 2>/dev/null | sed '/brook.sh monitor/d' > /tmp/crontab_brook.tmp 2>/dev/null || true
  crontab /tmp/crontab_brook.tmp
  rm -f /tmp/crontab_brook.tmp
  cron_config=$(crontab -l 2>/dev/null | grep "brook.sh monitor" || true)
  if [[ -n ${cron_config} ]]; then
    echo -e "${Error} 停止监控任务失败！"
  else
    echo -e "${Info} 已关闭 Brook 运行状态监控。"
  fi
}

#=================================================
# 升级脚本（从你的 GitHub 仓库拉最新）
#=================================================

Update_Shell() {
  echo -e "${Info} 正在从 GitHub 更新脚本..."
  local url="https://raw.githubusercontent.com/AKA668/brook/main/brook.sh"
  local script_path="${brook_dir}/brook.sh"
  mkdir -p "${brook_dir}"
  if curl -Ls "${url}" -o "${script_path}"; then
    chmod +x "${script_path}"
    echo -e "${Info} 已更新脚本到 ${script_path}"
    echo -e "${Tip} 下次可直接执行：${Green_font_prefix}bash ${script_path}${Font_color_suffix}"
  else
    echo -e "${Error} 脚本更新失败，请检查网络或仓库地址。"
  fi
}

#=================================================
# 主菜单 & 入口
#=================================================

check_sys
init_env

action=$1
if [[ "${action}" == "monitor" ]]; then
  crontab_monitor_brook
  exit 0
fi

echo && echo -e "┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓
┃      Brook 端口转发 一键管理脚本      ┃
┣━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┫
┃              版本: v${sh_ver}              ┃
┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛
━━━━━━━━━━━━
 ${Green_font_prefix} 0.${Font_color_suffix} 升级脚本
━━━━━━━━━━━━
 ${Green_font_prefix} 1.${Font_color_suffix} 安装 Brook
 ${Green_font_prefix} 2.${Font_color_suffix} 更新 Brook
 ${Green_font_prefix} 3.${Font_color_suffix} 卸载 Brook
━━━━━━━━━━━━
 ${Green_font_prefix} 4.${Font_color_suffix} 启动 Brook（启动所有启用规则）
 ${Green_font_prefix} 5.${Font_color_suffix} 停止 Brook（停止所有规则）
 ${Green_font_prefix} 6.${Font_color_suffix} 重启 Brook
━━━━━━━━━━━━
 ${Green_font_prefix} 7.${Font_color_suffix} 设置 Brook 端口转发（含批量添加/删除）
 ${Green_font_prefix} 8.${Font_color_suffix} 查看 Brook 端口转发
 ${Green_font_prefix} 9.${Font_color_suffix} 查看 Brook 日志
 ${Green_font_prefix}10.${Font_color_suffix} 监控 Brook 运行状态（启用/关闭）
━━━━━━━━━━━━" && echo

if [[ -e ${brook_file} ]]; then
  # 检查是否有运行中的规则
  running_num=$(ls /var/run/brook_pf_*.pid 2>/dev/null | wc -l)
  if [[ "${running_num}" -gt 0 ]]; then
    echo -e " 当前状态: ${Green_font_prefix}已安装${Font_color_suffix} 并 ${Green_font_prefix}有运行中的规则${Font_color_suffix}"
  else
    echo -e " 当前状态: ${Green_font_prefix}已安装${Font_color_suffix} 但 ${Red_font_prefix}未运行${Font_color_suffix}"
  fi
else
  echo -e " 当前状态: ${Red_font_prefix}未安装${Font_color_suffix}"
fi

echo
read -e -p " 请输入数字 [0-10]: " num
case "$num" in
  0)
    Update_Shell
    ;;
  1)
    Install_brook
    ;;
  2)
    Update_brook
    ;;
  3)
    Uninstall_brook
    ;;
  4)
    start_all_relays
    ;;
  5)
    stop_all_relays
    ;;
  6)
    restart_all_relays
    ;;
  7)
    Set_brook
    ;;
  8)
    check_installed_status
    list_port
    ;;
  9)
    View_Log
    ;;
  10)
    Set_crontab_monitor_brook
    ;;
  *)
    echo "请输入正确数字 [0-10]"
    ;;
esac
