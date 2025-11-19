#!/usr/bin/env bash
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin
export PATH

#=================================================
# Brook 转发 一键管理脚本（自用整合版）
# 版本：20250808
# 仓库：https://github.com/AKA668/brook
#=================================================

sh_ver="20250808"
filepath=$(cd "$(dirname "$0")"; pwd)
file="/usr/local/brook-pf"
brook_file="${file}/brook"
brook_conf="${file}/brook.conf"
brook_log="${file}/brook.log"
ddns_conf="${file}/ddns.conf"
Crontab_file="/usr/bin/crontab"

Green_font_prefix="\033[32m"
Red_font_prefix="\033[31m"
Green_background_prefix="\033[42;37m"
Red_background_prefix="\033[41;37m"
Font_color_suffix="\033[0m"

Info="${Green_font_prefix}[信息]${Font_color_suffix}"
Error="${Red_font_prefix}[错误]${Font_color_suffix}"
Tip="${Green_font_prefix}[注意]${Font_color_suffix}"

check_root(){
	[[ $EUID != 0 ]] && echo -e "${Error} 需要 ROOT 权限运行脚本！" && exit 1
}
check_sys(){
	if [[ -f /etc/redhat-release ]]; then
		release="centos"
	elif grep -Eqi "debian" /etc/issue; then
		release="debian"
	elif grep -Eqi "ubuntu" /etc/issue; then
		release="ubuntu"
	else
		release="other"
	fi
	bit=$(uname -m)
}
check_installed_status(){
	[[ ! -e ${brook_file} ]] && echo -e "${Error} Brook 未安装，请先安装！" && exit 1
}
check_crontab_installed_status(){
	if [[ ! -e ${Crontab_file} ]]; then
		echo -e "${Error} 未检测到 Crontab，开始安装..."
		if [[ ${release} == "centos" ]]; then
			yum install -y cronie || yum install -y crond
		else
			apt-get update -y
			apt-get install -y cron
		fi
		[[ ! -e ${Crontab_file} ]] && echo -e "${Error} Crontab 安装失败！" && exit 1
	fi
}
check_pid(){
	PID=$(ps -ef | grep "brook relays" | grep -v grep | grep -v ".sh" | awk '{print $2}')
}

Installation_dependency(){
	[[ -f /usr/share/zoneinfo/Asia/Shanghai ]] && \cp -f /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
	[[ ! -d ${file} ]] && mkdir -p ${file}
	[[ ! -f ${brook_conf} ]] && touch ${brook_conf}
	[[ ! -f ${ddns_conf} ]] && touch ${ddns_conf}
}

#=================================================
#            版本获取 / 下载（用你自己的仓库）
#=================================================

check_new_ver(){
	echo -e "请输入要下载安装的 Brook 版本号 ${Green_font_prefix}[例如: v20250808]${Font_color_suffix}
版本列表：${Green_font_prefix}https://github.com/AKA668/brook/releases${Font_color_suffix}"
	read -e -p "直接回车自动获取最新版本: " brook_new_ver
	if [[ -z ${brook_new_ver} ]]; then
		brook_new_ver=$(wget -qO- https://api.github.com/repos/AKA668/brook/releases \
			| grep '"tag_name"' | head -n 1 | awk -F '"' '{print $4}')
		[[ -z ${brook_new_ver} ]] && echo -e "${Error} 获取最新版本失败！" && exit 1
		echo -e "${Info} 检测到 Brook 最新版本为：${Green_font_prefix}${brook_new_ver}${Font_color_suffix}"
	else
		echo -e "${Info} 使用指定版本：${Green_font_prefix}${brook_new_ver}${Font_color_suffix}"
	fi
}

Download_brook(){
	[[ ! -d ${file} ]] && mkdir -p ${file}
	cd ${file} || exit 1
	echo -e "${Info} 开始下载 Brook ${Green_font_prefix}${brook_new_ver}${Font_color_suffix}"

	# AMD64 / x86_64
	if [[ ${bit} == "x86_64" ]] || [[ ${bit} == "amd64" ]]; then
		wget --no-check-certificate -N "https://github.com/AKA668/brook/releases/download/${brook_new_ver}/brook_linux_amd64"
		[[ -f brook_linux_amd64 ]] && mv brook_linux_amd64 brook

	# 386
	elif [[ ${bit} == "i386" ]] || [[ ${bit} == "i686" ]]; then
		wget --no-check-certificate -N "https://github.com/AKA668/brook/releases/download/${brook_new_ver}/brook_linux_386"
		[[ -f brook_linux_386 ]] && mv brook_linux_386 brook

	# ARMv7 / ARMv6
	elif [[ ${bit} == "armv7l" ]] || [[ ${bit} == "armv6l" ]]; then
		wget --no-check-certificate -N "https://github.com/AKA668/brook/releases/download/${brook_new_ver}/brook_linux_arm7"
		[[ -f brook_linux_arm7 ]] && mv brook_linux_arm7 brook

	# ARM64 / AARCH64
	elif [[ ${bit} == "aarch64" ]] || [[ ${bit} == "arm64" ]]; then
		wget --no-check-certificate -N "https://github.com/AKA668/brook/releases/download/${brook_new_ver}/brook_linux_arm64"
		[[ -f brook_linux_arm64 ]] && mv brook_linux_arm64 brook

	else
		echo -e "${Error} 暂不支持该架构：${bit}" && exit 1
	fi

	[[ ! -e "brook" ]] && echo -e "${Error} Brook 下载失败！" && exit 1
	chmod +x brook
	echo -e "${Info} Brook 下载完成：${Green_font_prefix}${brook_file}${Font_color_suffix}"
}


check_ver_comparison(){
	brook_now_ver=$(${brook_file} -v 2>/dev/null | awk '{print $3}')
	[[ -z ${brook_now_ver} ]] && echo -e "${Error} 无法获取当前 Brook 版本！" && exit 1
	brook_now_ver="v${brook_now_ver}"
	if [[ "${brook_now_ver}" != "${brook_new_ver}" ]]; then
		echo -e "${Info} 发现新版本：${Green_font_prefix}${brook_new_ver}${Font_color_suffix}，当前版本：${Red_font_prefix}${brook_now_ver}${Font_color_suffix}"
		read -e -p "确认更新？[Y/n] " yn
		[[ -z "${yn}" ]] && yn="y"
		if [[ ${yn} == [Yy] ]]; then
			check_pid
			[[ -n ${PID} ]] && kill -9 ${PID}
			rm -f ${brook_file}
			Download_brook
			Start_brook
		else
			echo -e "${Info} 已取消更新。"
		fi
	else
		echo -e "${Info} 当前已是最新版本：${Green_font_prefix}${brook_now_ver}${Font_color_suffix}"
	fi
}

#=================================================
#                 服务脚本
#=================================================

Service_brook(){
	if [[ ${release} == "centos" ]]; then
		wget --no-check-certificate -O /etc/init.d/brook-pf \
			"https://raw.githubusercontent.com/boji6681/doubi/master/service/brook-pf_centos"
		chmod +x /etc/init.d/brook-pf
		chkconfig --add brook-pf
		chkconfig brook-pf on
	else
		wget --no-check-certificate -O /etc/init.d/brook-pf \
			"https://raw.githubusercontent.com/boji6681/doubi/master/service/brook-pf_debian"
		chmod +x /etc/init.d/brook-pf
		update-rc.d -f brook-pf defaults
	fi
	echo -e "${Info} Brook 服务管理脚本安装完成！"
}
#=================================================
#               iptables 管理
#=================================================

Add_iptables(){
	iptables -I INPUT -m state --state NEW -m tcp -p tcp --dport ${bk_port} -j ACCEPT
	iptables -I INPUT -m state --state NEW -m udp -p udp --dport ${bk_port} -j ACCEPT
}
Del_iptables(){
	iptables -D INPUT -m state --state NEW -m tcp -p tcp --dport ${port} -j ACCEPT
	iptables -D INPUT -m state --state NEW -m udp -p udp --dport ${port} -j ACCEPT
}
Save_iptables(){
	if [[ ${release} == "centos" ]]; then
		service iptables save >/dev/null 2>&1
	else
		iptables-save > /etc/iptables.up.rules
	fi
}
Set_iptables(){
	if [[ ${release} == "centos" ]]; then
		service iptables save >/dev/null 2>&1
		chkconfig --level 2345 iptables on
	else
		iptables-save > /etc/iptables.up.rules
		echo -e '#!/bin/bash\n/sbin/iptables-restore < /etc/iptables.up.rules' > /etc/network/if-pre-up.d/iptables
		chmod +x /etc/network/if-pre-up.d/iptables
	fi
}

#=================================================
#              配置文件 / 端口操作
#=================================================

Read_config(){
	[[ ! -e ${brook_conf} ]] && echo -e "${Error} Brook 配置文件不存在！" && exit 1
	user_all=$(grep -v '^\s*$' "${brook_conf}")
	user_all_num=$(echo "${user_all}" | wc -l)
	[[ -z ${user_all} ]] && echo -e "${Error} 配置文件中没有任何端口转发！" && exit 1
}

check_port(){
	local check_port_1=$1
	local user_all
	user_all=$(grep -v '^\s*$' "${brook_conf}")
	local check_port_statu
	check_port_statu=$(echo "${user_all}" | awk '{print $1}' | grep -w "${check_port_1}")
	if [[ -n "${check_port_statu}" ]]; then
		return 0
	else
		return 1
	fi
}

list_port(){
	local port_Type=$1
	local user_all
	user_all=$(grep -v '^\s*$' "${brook_conf}")
	if [[ -z "${user_all}" ]]; then
		echo -e "${Info} 目前 Brook 配置为空。"
		[[ "${port_Type}" == "ADD" ]] || exit 1
	else
		user_num=$(echo -e "${user_all}" | wc -l)
		user_list_all=""
		for((integer = 1; integer <= ${user_num}; integer++)); do
			user_port=$(echo "${user_all}" | sed -n "${integer}p" | awk '{print $1}')
			user_ip_pf=$(echo "${user_all}" | sed -n "${integer}p" | awk '{print $2}')
			user_port_pf=$(echo "${user_all}" | sed -n "${integer}p" | awk '{print $3}')
			user_Enabled_pf=$(echo "${user_all}" | sed -n "${integer}p" | awk '{print $4}')
			if [[ ${user_Enabled_pf} == "0" ]]; then
				user_Enabled_pf_1="${Red_font_prefix}禁用${Font_color_suffix}"
			else
				user_Enabled_pf_1="${Green_font_prefix}启用${Font_color_suffix}"
			fi
			user_list_all="${user_list_all}本地端口: ${Green_font_prefix}${user_port}${Font_color_suffix}\t 目标: ${Green_font_prefix}${user_ip_pf}:${user_port_pf}${Font_color_suffix}\t 状态: ${user_Enabled_pf_1}\n"
		done
		ip=$(wget -qO- -t1 -T2 ipinfo.io/ip || wget -qO- -t1 -T2 api.ip.sb/ip || wget -qO- -t1 -T2 members.3322.org/dyndns/getip || echo "VPS_IP")
		echo -e "当前端口转发数: ${Green_background_prefix} ${user_num} ${Font_color_suffix} 当前服务器IP: ${Green_background_prefix} ${ip} ${Font_color_suffix}"
		echo -e "${user_list_all}"
		echo -e "========================\n"
	fi
}

Set_port(){
	while true; do
		echo -e "请输入 Brook 本地监听端口 [1-65535]（端口不能重复）"
		read -e -p "(默认取消): " bk_port
		[[ -z "${bk_port}" ]] && echo "已取消..." && exit 1
		echo $((${bk_port}+0)) &>/dev/null || { echo "请输入正确的数字！"; continue; }
		if [[ ${bk_port} -ge 1 && ${bk_port} -le 65535 ]]; then
			echo && echo "========================"
			echo -e " 本地监听端口 : ${Red_background_prefix} ${bk_port} ${Font_color_suffix}"
			echo "========================" && echo
			break
		else
			echo "端口范围错误，请重新输入。"
		fi
	done
}

Set_IP_pf(){
	echo "请输入被转发的 IP 或域名（支持 DDNS 域名）："
	read -e -p "(默认取消): " bk_ip_pf
	[[ -z "${bk_ip_pf}" ]] && echo "已取消..." && exit 1
	echo && echo "========================"
	echo -e " 被转发 IP/域名 : ${Red_background_prefix} ${bk_ip_pf} ${Font_color_suffix}"
	echo "========================" && echo
}

Set_port_pf(){
	while true; do
		echo -e "请输入目标端口 [1-65535]"
		read -e -p "(默认取消): " bk_port_pf
		[[ -z "${bk_port_pf}" ]] && echo "已取消..." && exit 1
		echo $((${bk_port_pf}+0)) &>/dev/null || { echo "请输入正确的数字！"; continue; }
		if [[ ${bk_port_pf} -ge 1 && ${bk_port_pf} -le 65535 ]]; then
			echo && echo "========================"
			echo -e " 目标端口 : ${Red_background_prefix} ${bk_port_pf} ${Font_color_suffix}"
			echo "========================" && echo
			break
		else
			echo "端口范围错误，请重新输入。"
		fi
	done
}

Set_pf_Enabled(){
	echo -e "是否立即启用该端口转发？ [Y/n]"
	read -e -p "(默认: Y 启用): " pf_Enabled_un
	[[ -z ${pf_Enabled_un} ]] && pf_Enabled_un="y"
	if [[ ${pf_Enabled_un} == [Yy] ]]; then
		bk_Enabled="1"
	else
		bk_Enabled="0"
	fi
}

Add_pf(){
	while true; do
		list_port "ADD"
		Set_port
		check_port "${bk_port}" && { echo -e "${Error} 本地端口已存在 [${bk_port}]！"; exit 1; }
		Set_IP_pf
		Set_port_pf
		Set_pf_Enabled
		echo "${bk_port} ${bk_ip_pf} ${bk_port_pf} ${bk_Enabled}" >> ${brook_conf}
		Add_iptables
		Save_iptables
		echo -e "${Info} 端口转发添加成功：${Green_font_prefix}${bk_port} => ${bk_ip_pf}:${bk_port_pf}${Font_color_suffix}\n"
		read -e -p "是否继续添加？[Y/n]: " addyn
		[[ -z ${addyn} ]] && addyn="y"
		[[ ${addyn} == [Nn] || ${addyn} == [n] ]] && Restart_brook && break
	done
}

Del_pf(){
	while true; do
		list_port
		Set_port
		check_port "${bk_port}" || { echo -e "${Error} 本地端口不存在 [${bk_port}]！"; exit 1; }
		sed -i "/^${bk_port} /d" ${brook_conf}
		port=${bk_port}
		Del_iptables
		Save_iptables
		echo -e "${Info} 端口转发删除成功：${Green_font_prefix}${bk_port}${Font_color_suffix}\n"
		port_num=$(grep -v '^\s*$' ${brook_conf} | wc -l)
		if [[ ${port_num} == 0 ]]; then
			echo -e "${Error} 已无任何端口！"
			check_pid
			[[ -n ${PID} ]] && Stop_brook
			break
		else
			read -e -p "是否继续删除？[Y/n]: " delyn
			[[ -z ${delyn} ]] && delyn="y"
			[[ ${delyn} == [Nn] || ${delyn} == [n] ]] && Restart_brook && break
		fi
	done
}

Set_port_Modify(){
	while true; do
		echo -e "请输入要修改的【原本地监听端口】 [1-65535]"
		read -e -p "(默认取消): " bk_port_Modify
		[[ -z "${bk_port_Modify}" ]] && echo "已取消..." && exit 1
		echo $((${bk_port_Modify}+0)) &>/dev/null || { echo "请输入正确数字！"; continue; }
		if [[ ${bk_port_Modify} -ge 1 && ${bk_port_Modify} -le 65535 ]]; then
			check_port "${bk_port_Modify}" && break || echo -e "${Error} 该端口不存在 [${bk_port_Modify}]！"
		else
			echo "端口范围错误，请重新输入。"
		fi
	done
}

Modify_pf(){
	list_port
	Set_port_Modify
	echo -e "\n${Info} 开始输入新端口及目标...\n"
	Set_port
	check_port "${bk_port}" && { echo -e "${Error} 新端口已存在 [${bk_port}]！"; exit 1; }
	Set_IP_pf
	Set_port_pf
	Set_pf_Enabled
	sed -i "/^${bk_port_Modify} /d" ${brook_conf}
	echo "${bk_port} ${bk_ip_pf} ${bk_port_pf} ${bk_Enabled}" >> ${brook_conf}
	port=${bk_port_Modify}
	Del_iptables
	bk_port=${bk_port}
	Add_iptables
	Save_iptables
	Restart_brook
	echo -e "${Info} 端口转发修改成功：${Green_font_prefix}${bk_port} => ${bk_ip_pf}:${bk_port_pf}${Font_color_suffix}\n"
}

Modify_Enabled_pf(){
	list_port
	Set_port_Modify
	user_pf_text=$(grep "^${bk_port_Modify} " ${brook_conf} | head -n1)
	[[ -z "${user_pf_text}" ]] && echo -e "${Error} 未找到该端口配置！" && exit 1
	user_port_text=$(echo ${user_pf_text} | awk '{print $1}')
	user_ip_pf_text=$(echo ${user_pf_text} | awk '{print $2}')
	user_port_pf_text=$(echo ${user_pf_text} | awk '{print $3}')
	user_Enabled_pf_text=$(echo ${user_pf_text} | awk '{print $4}')
	if [[ ${user_Enabled_pf_text} == "0" ]]; then
		echo -e "该端口当前为 ${Red_font_prefix}禁用${Font_color_suffix}，是否 ${Green_font_prefix}启用${Font_color_suffix}？[Y/n]"
		read -e -p "(默认: Y): " user_Enabled_pf_text_un
		[[ -z ${user_Enabled_pf_text_un} ]] && user_Enabled_pf_text_un="y"
		if [[ ${user_Enabled_pf_text_un} == [Yy] ]]; then
			user_Enabled_pf_text_1="1"
		else
			echo "已取消..." && exit 0
		fi
	else
		echo -e "该端口当前为 ${Green_font_prefix}启用${Font_color_suffix}，是否 ${Red_font_prefix}禁用${Font_color_suffix}？[Y/n]"
		read -e -p "(默认: Y): " user_Enabled_pf_text_un
		[[ -z ${user_Enabled_pf_text_un} ]] && user_Enabled_pf_text_un="y"
		if [[ ${user_Enabled_pf_text_un} == [Yy] ]]; then
			user_Enabled_pf_text_1="0"
		else
			echo "已取消..." && exit 0
		fi
	fi
	sed -i "/^${bk_port_Modify} /d" ${brook_conf}
	echo "${user_port_text} ${user_ip_pf_text} ${user_port_pf_text} ${user_Enabled_pf_text_1}" >> ${brook_conf}
	Restart_brook
	echo -e "${Info} 端口状态修改成功：${Green_font_prefix}${user_port_text}${Font_color_suffix} => 状态 ${Green_font_prefix}${user_Enabled_pf_text_1}${Font_color_suffix}\n"
}

#==================== 批量添加 / 删除 ====================#

Batch_Add_pf(){
	echo -e "${Tip} 批量添加格式：一行一条，格式：本地端口 目标IP/域名 目标端口"
	echo -e "示例：\n 10000 1.2.3.4 10000\n 10001 example.com 443"
	echo -e "输入完成后，空行直接回车结束。"
	while true; do
		read -e -p "请输入一条规则（或直接回车结束）： " line
		[[ -z "${line}" ]] && break
		bk_port=$(echo "${line}" | awk '{print $1}')
		bk_ip_pf=$(echo "${line}" | awk '{print $2}')
		bk_port_pf=$(echo "${line}" | awk '{print $3}')
		[[ -z "${bk_port}" || -z "${bk_ip_pf}" || -z "${bk_port_pf}" ]] && { echo -e "${Error} 格式不正确，跳过该行"; continue; }
		check_port "${bk_port}" && { echo -e "${Error} 端口已存在 [${bk_port}]，跳过"; continue; }
		bk_Enabled="1"
		echo "${bk_port} ${bk_ip_pf} ${bk_port_pf} ${bk_Enabled}" >> ${brook_conf}
		Add_iptables
		echo -e "${Info} 已添加：${Green_font_prefix}${bk_port} => ${bk_ip_pf}:${bk_port_pf}${Font_color_suffix}"
	done
	Save_iptables
	Restart_brook
	echo -e "${Info} 批量添加完成。"
}

Batch_Del_pf(){
	echo -e "${Tip} 请输入要批量删除的本地端口（空格分隔），例如：10000 10001 10002"
	read -e -p "端口列表: " ports
	[[ -z "${ports}" ]] && echo "已取消..." && return
	for p in ${ports}; do
		port=${p}
		check_port "${port}" || { echo -e "${Error} 端口不存在 [${port}]，跳过"; continue; }
		sed -i "/^${port} /d" ${brook_conf}
		Del_iptables
		echo -e "${Info} 已删除端口：${Green_font_prefix}${port}${Font_color_suffix}"
	done
	Save_iptables
	Restart_brook
	echo -e "${Info} 批量删除完成。"
}

Set_brook(){
	check_installed_status
	echo && echo -e "你要做什么？
 ${Green_font_prefix}1.${Font_color_suffix}  添加端口转发
 ${Green_font_prefix}2.${Font_color_suffix}  删除端口转发
 ${Green_font_prefix}3.${Font_color_suffix}  修改端口转发
 ${Green_font_prefix}4.${Font_color_suffix}  启用/禁用端口
 ${Green_font_prefix}5.${Font_color_suffix}  批量添加端口转发
 ${Green_font_prefix}6.${Font_color_suffix}  批量删除端口转发
 " && echo
	read -e -p "(默认取消): " bk_modify
	[[ -z "${bk_modify}" ]] && echo "已取消..." && return
	case "${bk_modify}" in
		1) Add_pf ;;
		2) Del_pf ;;
		3) Modify_pf ;;
		4) Modify_Enabled_pf ;;
		5) Batch_Add_pf ;;
		6) Batch_Del_pf ;;
		*) echo -e "${Error} 请输入正确数字 [1-6]" ;;
	esac
}

#==================== DDNS 监控（只影响对应端口配置） ====================#

show_ddns(){
	echo -e "当前 DDNS 监控列表（ddns.conf）："
	if [[ ! -s ${ddns_conf} ]]; then
		echo -e "${Info} 暂无 DDNS 监控记录。"
	else
		nl -ba ${ddns_conf}
	fi
}

add_ddns(){
	echo -e "${Tip} 添加 DDNS 监控：会根据域名解析变化自动更新 brook.conf 中对应端口的目标 IP，并重启 Brook（不删除其他端口配置）。"
	read -e -p "请输入本地端口: " ddns_port
	[[ -z "${ddns_port}" ]] && echo "已取消..." && return
	check_port "${ddns_port}" || { echo -e "${Error} 该端口在 brook.conf 中不存在，请先添加端口转发！"; return; }
	read -e -p "请输入需要监控的域名: " ddns_domain
	[[ -z "${ddns_domain}" ]] && echo "已取消..." && return
	current_ip=$(getent hosts "${ddns_domain}" | awk '{print $1}' | head -n1)
	[[ -z "${current_ip}" ]] && echo -e "${Error} 无法解析域名：${ddns_domain}" && return
	# 删除旧记录
	sed -i "/^${ddns_port} /d" ${ddns_conf}
	echo "${ddns_port} ${ddns_domain} ${current_ip}" >> ${ddns_conf}
	echo -e "${Info} 已添加 DDNS 监控：端口 ${ddns_port} => 域名 ${ddns_domain} (当前IP: ${current_ip})"
}

del_ddns(){
	show_ddns
	read -e -p "请输入要删除监控的端口: " dport
	[[ -z "${dport}" ]] && echo "已取消..." && return
	sed -i "/^${dport} /d" ${ddns_conf}
	echo -e "${Info} 已删除端口 ${dport} 的 DDNS 监控记录。"
}

ddns_monitor_once(){
	[[ ! -s ${ddns_conf} ]] && exit 0
	while read -r line; do
		[[ -z "${line}" ]] && continue
		dport=$(echo "${line}" | awk '{print $1}')
		ddomain=$(echo "${line}" | awk '{print $2}')
		last_ip=$(echo "${line}" | awk '{print $3}')
		[[ -z "${dport}" || -z "${ddomain}" ]] && continue
		current_ip=$(getent hosts "${ddomain}" | awk '{print $1}' | head -n1)
		[[ -z "${current_ip}" ]] && continue
		if [[ "${current_ip}" != "${last_ip}" ]]; then
			echo -e "${Info} 检测到域名 ${ddomain} 解析变更：${last_ip} -> ${current_ip}，端口 ${dport}"
			# 更新 brook.conf 中对应端口的目标 IP（不动其他端口）
			if grep -q "^${dport} " "${brook_conf}"; then
				old_ip=$(grep "^${dport} " "${brook_conf}" | head -n1 | awk '{print $2}')
				sed -i "s/^${dport} ${old_ip} /${dport} ${current_ip} /" "${brook_conf}"
				echo -e "${Info} 已更新 brook.conf 中端口 ${dport} 的目标 IP：${old_ip} -> ${current_ip}"
				Restart_brook
			fi
			# 更新 ddns_conf 中记录的 last_ip
			sed -i "s/^${dport} ${ddomain} .*$/${dport} ${ddomain} ${current_ip}/" "${ddns_conf}"
		fi
	done < "${ddns_conf}"
}

Set_ddns_menu(){
	echo && echo -e "DDNS 监控管理：
 ${Green_font_prefix}1.${Font_color_suffix} 查看 DDNS 监控列表
 ${Green_font_prefix}2.${Font_color_suffix} 添加 DDNS 监控
 ${Green_font_prefix}3.${Font_color_suffix} 删除 DDNS 监控
 ${Green_font_prefix}4.${Font_color_suffix} 设置/取消 DDNS 定时任务
"
	read -e -p "请选择 [1-4] (默认取消): " dopt
	[[ -z "${dopt}" ]] && echo "已取消..." && return
	case "${dopt}" in
		1) show_ddns ;;
		2) add_ddns ;;
		3) del_ddns ;;
		4) Set_crontab_ddns ;;
		*) echo -e "${Error} 请输入正确数字 [1-4]" ;;
	esac
}
#=================================================
#                Crontab 监控 / DDNS
#=================================================

crontab_monitor_brook_cron_start(){
	crontab -l 2>/dev/null > /tmp/crontab.bak
	sed -i "/brook-pf.sh monitor/d" /tmp/crontab.bak
	echo -e "\n* * * * * /bin/bash ${filepath}/$(basename "$0") monitor" >> /tmp/crontab.bak
	crontab /tmp/crontab.bak
	rm -f /tmp/crontab.bak
	cron_config=$(crontab -l | grep "brook-pf.sh monitor" || true)
	if [[ -z ${cron_config} ]]; then
		echo -e "${Error} Brook 运行状态监控 启用失败！"
	else
		echo -e "${Info} Brook 运行状态监控 已启用（每分钟检查一次）。"
	fi
}
crontab_monitor_brook_cron_stop(){
	crontab -l 2>/dev/null > /tmp/crontab.bak
	sed -i "/brook-pf.sh monitor/d" /tmp/crontab.bak
	crontab /tmp/crontab.bak
	rm -f /tmp/crontab.bak
	echo -e "${Info} Brook 运行状态监控 已关闭。"
}
crontab_monitor_brook(){
	check_installed_status
	check_pid
	if [[ -z ${PID} ]]; then
		echo -e "${Error} [$(date "+%F %T")] 检测到 Brook 未运行，尝试启动..." | tee -a ${brook_log}
		/etc/init.d/brook-pf start
		sleep 1
		check_pid
		if [[ -z ${PID} ]]; then
			echo -e "${Error} [$(date "+%F %T")] Brook 启动失败..." | tee -a ${brook_log}
		else
			echo -e "${Info} [$(date "+%F %T")] Brook 启动成功。" | tee -a ${brook_log}
		fi
	else
		echo -e "${Info} [$(date "+%F %T")] Brook 运行正常（PID: ${PID}）" >> ${brook_log}
	fi
}

Set_crontab_monitor_brook(){
	check_installed_status
	check_crontab_installed_status
	crontab_monitor_brook_status=$(crontab -l 2>/dev/null | grep "brook-pf.sh monitor" || true)
	if [[ -z "${crontab_monitor_brook_status}" ]]; then
		echo -e "当前监控模式：${Red_font_prefix}未开启${Font_color_suffix}"
		read -e -p "是否开启运行状态监控？[Y/n]: " cm
		[[ -z "${cm}" ]] && cm="y"
		[[ ${cm} == [Yy] ]] && crontab_monitor_brook_cron_start || echo "已取消..."
	else
		echo -e "当前监控模式：${Green_font_prefix}已开启${Font_color_suffix}"
		read -e -p "是否关闭运行状态监控？[y/N]: " cm
		[[ -z "${cm}" ]] && cm="n"
		[[ ${cm} == [Yy] ]] && crontab_monitor_brook_cron_stop || echo "已取消..."
	fi
}

#---- DDNS 定时任务 ----#
Set_crontab_ddns(){
	check_crontab_installed_status
	cron_exist=$(crontab -l 2>/dev/null | grep "brook.sh ddns" || true)
	if [[ -z "${cron_exist}" ]]; then
		echo -e "当前 DDNS 定时任务：${Red_font_prefix}未开启${Font_color_suffix}"
		read -e -p "是否每 1 分钟执行一次 DDNS 检查？[Y/n]: " dd
		[[ -z "${dd}" ]] && dd="y"
		if [[ ${dd} == [Yy] ]]; then
			crontab -l 2>/dev/null > /tmp/crontab.bak
			sed -i "/brook.sh ddns/d" /tmp/crontab.bak
			echo -e "\n* * * * * /bin/bash ${filepath}/$(basename "$0") ddns" >> /tmp/crontab.bak
			crontab /tmp/crontab.bak
			rm -f /tmp/crontab.bak
			echo -e "${Info} DDNS 定时监控已开启。"
		else
			echo "已取消..."
		fi
	else
		echo -e "当前 DDNS 定时任务：${Green_font_prefix}已开启${Font_color_suffix}"
		read -e -p "是否关闭 DDNS 定时监控？[y/N]: " dd
		[[ -z "${dd}" ]] && dd="n"
		if [[ ${dd} == [Yy] ]]; then
			crontab -l 2>/dev/null > /tmp/crontab.bak
			sed -i "/brook.sh ddns/d" /tmp/crontab.bak
			crontab /tmp/crontab.bak
			rm -f /tmp/crontab.bak
			echo -e "${Info} DDNS 定时监控已关闭。"
		else
			echo "已取消..."
		fi
	fi
}

#=================================================
#          安装 / 启停 / 更新 / 卸载
#=================================================

Install_brook(){
	check_root
	[[ -e ${brook_file} ]] && echo -e "${Error} 检测到 Brook 已安装！" && exit 1
	echo -e "${Info} 开始安装依赖..."
	Installation_dependency
	echo -e "${Info} 检测版本..."
	check_new_ver
	echo -e "${Info} 下载 Brook..."
	Download_brook
	echo -e "${Info} 安装服务脚本..."
	Service_brook
	echo -e "${Info} 写入配置文件..."
	: > "${brook_conf}"
	echo -e "${Info} 设置 iptables..."
	Set_iptables
	echo -e "${Info} Brook 安装完成！请使用菜单【7】设置端口转发。"
}

Start_brook(){
	check_installed_status
	check_pid
	[[ -n ${PID} ]] && echo -e "${Error} Brook 已在运行，PID: ${PID}" && return
	/etc/init.d/brook-pf start
}

Stop_brook(){
	check_installed_status
	check_pid
	[[ -z ${PID} ]] && echo -e "${Error} Brook 未在运行。" && return
	/etc/init.d/brook-pf stop
}

Restart_brook(){
	check_installed_status
	check_pid
	[[ -n ${PID} ]] && /etc/init.d/brook-pf stop
	/etc/init.d/brook-pf start
}

Update_brook(){
	check_installed_status
	echo -e "${Info} 即将更新 Brook..."
	check_new_ver
	check_ver_comparison
}

Uninstall_brook(){
	check_installed_status
	echo -e "确定要卸载 Brook 并清理所有配置？[y/N]"
	read -e -p "(默认: N): " unyn
	[[ -z ${unyn} ]] && unyn="n"
	if [[ ${unyn} == [Yy] ]]; then
		check_pid
		[[ -n ${PID} ]] && kill -9 ${PID}
		if [[ -f ${brook_conf} ]]; then
			user_all=$(grep -v '^\s*$' ${brook_conf})
			user_all_num=$(echo "${user_all}" | wc -l)
			if [[ -n ${user_all} ]]; then
				for((integer = 1; integer <= ${user_all_num}; integer++)); do
					port=$(echo "${user_all}" | sed -n "${integer}p" | awk '{print $1}')
					Del_iptables
				done
				Save_iptables
			fi
		fi
		rm -rf ${file}
		if [[ ${release} == "centos" ]]; then
			chkconfig --del brook-pf
		else
			update-rc.d -f brook-pf remove
		fi
		rm -f /etc/init.d/brook-pf
		echo && echo "Brook 已卸载完成！" && echo
	else
		echo && echo "卸载已取消..." && echo
	fi
}

View_Log(){
	check_installed_status
	[[ ! -e ${brook_log} ]] && echo -e "${Error} Brook 日志文件不存在！" && exit 1
	echo && echo -e "${Tip} 按 ${Red_font_prefix}Ctrl + C${Font_color_suffix} 退出查看。" && echo
	tail -f ${brook_log}
}

#=================================================
#             脚本自更新（用你仓库）
#=================================================

Update_Shell(){
	sh_new_ver=$(wget --no-check-certificate -qO- -t1 -T3 "https://raw.githubusercontent.com/AKA668/brook/main/brook.sh" \
		| grep 'sh_ver="' | head -1 | awk -F '"' '{print $2}')
	[[ -z ${sh_new_ver} ]] && echo -e "${Error} 无法连接到 Github 获取新版本！" && exit 0
	echo -e "当前脚本版本：${sh_ver}，最新版本：${sh_new_ver}"
	if [[ "${sh_new_ver}" != "${sh_ver}" ]]; then
		read -e -p "确认更新脚本？[Y/n]: " upyn
		[[ -z "${upyn}" ]] && upyn="y"
		if [[ ${upyn} == [Yy] ]]; then
			wget -N --no-check-certificate "https://raw.githubusercontent.com/AKA668/brook/main/brook.sh" -O "$0"
			chmod +x "$0"
			echo -e "${Info} 脚本已更新为最新版本：${sh_new_ver}"
			exit 0
		else
			echo "已取消更新。"
		fi
	else
		echo -e "${Info} 当前脚本已是最新版本。"
	fi
}

#=================================================
#           安装 /usr/bin/brook 快捷命令
#=================================================

Install_shortcut(){
	if [[ -x /usr/bin/brook ]]; then
		echo -e "${Info} /usr/bin/brook 已存在。"
	else
		cp -f "$0" /usr/bin/brook 2>/dev/null || ln -sf "${filepath}/$(basename "$0")" /usr/bin/brook
		chmod +x /usr/bin/brook
		echo -e "${Info} 已安装快捷命令：直接输入 ${Green_font_prefix}brook${Font_color_suffix} 即可打开菜单。"
	fi
}

#=================================================
#                 主菜单（循环）
#=================================================

show_menu(){
	echo && echo -e "━━━━━━━━━━━━ Brook 端口转发 一键管理脚本 [v${sh_ver}] ━━━━━━━━━━━━
 ${Green_font_prefix} 0.${Font_color_suffix} 升级脚本 (更新 brook.sh)
━━━━━━━━━━━━
 ${Green_font_prefix} 1.${Font_color_suffix} 安装 Brook
 ${Green_font_prefix} 2.${Font_color_suffix} 更新 Brook
 ${Green_font_prefix} 3.${Font_color_suffix} 卸载 Brook
━━━━━━━━━━━━
 ${Green_font_prefix} 4.${Font_color_suffix} 启动 Brook
 ${Green_font_prefix} 5.${Font_color_suffix} 停止 Brook
 ${Green_font_prefix} 6.${Font_color_suffix} 重启 Brook
━━━━━━━━━━━━
 ${Green_font_prefix} 7.${Font_color_suffix} 设置 Brook 端口转发（含单个/批量）
 ${Green_font_prefix} 8.${Font_color_suffix} 查看 Brook 端口转发
 ${Green_font_prefix} 9.${Font_color_suffix} 查看 Brook 日志
 ${Green_font_prefix}10.${Font_color_suffix} 监控 Brook 运行状态（Crontab）
 ${Green_font_prefix}11.${Font_color_suffix} DDNS 监控管理
 ${Green_font_prefix}12.${Font_color_suffix} 安装 brook 快捷命令（输入 brook 出菜单）
 ${Green_font_prefix}13.${Font_color_suffix} 退出脚本
━━━━━━━━━━━━"
	if [[ -e ${brook_file} ]]; then
		check_pid
		if [[ -n "${PID}" ]]; then
			echo -e " 当前状态: ${Green_font_prefix}已安装${Font_color_suffix} 并 ${Green_font_prefix}已启动${Font_color_suffix} (PID: ${PID})"
		else
			echo -e " 当前状态: ${Green_font_prefix}已安装${Font_color_suffix} 但 ${Red_font_prefix}未启动${Font_color_suffix}"
		fi
	else
		echo -e " 当前状态: ${Red_font_prefix}未安装${Font_color_suffix}"
	fi
	echo
}

main_menu_loop(){
	while true; do
		show_menu
		read -e -p " 请输入数字 [0-13]: " num
		case "$num" in
			0) Update_Shell ;;
			1) Install_brook ;;
			2) Update_brook ;;
			3) Uninstall_brook ;;
			4) Start_brook ;;
			5) Stop_brook ;;
			6) Restart_brook ;;
			7) Set_brook ;;
			8) check_installed_status; list_port ;;
			9) View_Log ;;
			10) Set_crontab_monitor_brook ;;
			11) Set_ddns_menu ;;
			12) Install_shortcut ;;
			13) echo "已退出脚本。"; break ;;
			*) echo "请输入正确数字 [0-13]" ;;
		esac
		echo -e "\n按任意键回到菜单..." && read -n1 -s
	done
}

#=================================================
#                入口参数处理
#=================================================

check_sys
action=$1
if [[ "${action}" == "monitor" ]]; then
	crontab_monitor_brook
elif [[ "${action}" == "ddns" ]]; then
	ddns_monitor_once
else
	main_menu_loop
fi
