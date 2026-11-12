#!/bin/sh
# =============================================================================
#  portfwd.sh — 端口转发一键配置（NAT 中转机 → 落地机）
#
#  一条命令跑完整个流程：
#     1) 输入落地机 IP 和端口（端口必填，没有 443 默认值）
#     2) ping 10 次，看平均延迟和丢包，给出判断，问你要不要继续
#     3) 环境检查 → 确定转发机 NAT 端口（默认随机 5 位）
#     4) 写入 iptables 并保存 → 设置开机自启
#     5) 提醒你去做路由器映射 / 防火墙放行
#
#  原理与手工步骤完全一致：
#     1) net.ipv4.ip_forward = 1
#     2) nat/PREROUTING   DNAT        改目标为落地机 IP:端口
#     3) nat/POSTROUTING  MASQUERADE  源地址伪装，保证回包原路返回
#
#  设计要点（为什么可以放心重复执行）：
#     * 幂等：加规则前先 `iptables -C` 查重，绝不叠加
#     * 标记：自己加的规则带 portfwd: 注释，重放前先清掉旧的，换落地机不留残留
#     * 配置：映射落在 /etc/portfwd.conf，改端口=改文件+apply
#     * 持久：iptables save + systemd 服务 / OpenRC 钩子 + 开机重放
#
#  精简系统适配（先补依赖，再动手）：
#     * 自动识别包管理器（apk / apt / dnf / yum / microdnf / opkg）并装 iptables
#     * apt 索引过期时先 update 再重试安装
#     * 显式 modprobe 内核模块（ip_tables / iptable_nat / nf_nat / xt_MASQUERADE ...）
#     * iptables 默认后端不可用时自动切到 iptables-legacy / iptables-nft
#     * 缺 busybox applet（awk/sed/cut/mktemp...）时尝试补 busybox/coreutils
#     * 只依赖 POSIX sh，不依赖 xargs/sed 删除规则、不依赖 bash 数组
#     * 没有 sysctl 就直接写 /proc；没有 iptables-save 就靠开机钩子重放
#
#  发行版支持：
#     * Alpine（OpenRC）：/etc/local.d/portfwd.start + rc-update
#     * Debian / Ubuntu（systemd）：/etc/systemd/system/portfwd.service
#     * 容器 / 其他 init：跳过开机自启，其余功能不受影响
#     * 普通用户执行时自动 sudo 提权（不使用 sudo -E，兼容默认 sudoers）
# =============================================================================

# 说明：下面出现的 "-j $target" 有意不加引号 —— iptables 的 target 需要拆成多个
# 参数（例如 DNAT --to-destination 1.2.3.4:443），因此本文件忽略 SC2086。
# shellcheck disable=SC2086
VERSION="1.2.0"

CONF=${CONF:-/etc/portfwd.conf}
OPEN_FILE=${OPEN_FILE:-/etc/portfwd.open}
IPT=${IPT:-iptables}
QUIET=0
ASSUME_YES=0
COMMENT_OK=0
MODULES_LOADED=0
PKG=""
SELF=$(readlink -f "$0" 2>/dev/null || echo "$0")
CONF_HEAD='# 本地端口  落地IP  落地端口   —— 由 portfwd.sh 维护，可手工编辑后执行 portfwd.sh apply'

# -----------------------------------------------------------------------------
# 输出
# -----------------------------------------------------------------------------
out()  { [ "$QUIET" = 1 ] && return 0; printf '%s\n' "$*"; }
info() { [ "$QUIET" = 1 ] && return 0; printf '[*] %s\n' "$*"; }
ok()   { [ "$QUIET" = 1 ] && return 0; printf '[OK] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
die()  { printf '[x] %s\n' "$*" >&2; exit 1; }

# -----------------------------------------------------------------------------
# 参数校验
# -----------------------------------------------------------------------------
is_port() {
	case "$1" in '' | *[!0-9]*) return 1 ;; esac
	[ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

is_ipv4() {
	printf '%s\n' "$1" | awk -F'[.]' '
		NF != 4 { exit 1 }
		{ for (i = 1; i <= 4; i++) if ($i !~ /^[0-9]+$/ || $i + 0 > 255) exit 1 }
		{ exit 0 }'
}

is_hostname() {
	case "$1" in '' | *[!0-9A-Za-z.-]*) return 1 ;; esac
	case "$1" in -* | *. | .* | *..*) return 1 ;; esac
	return 0
}

check_target() {
	if is_ipv4 "$1"; then return 0; fi
	if is_hostname "$1"; then
		warn "目标 '$1' 不是 IPv4，将交给 iptables 解析域名（建议直接写 IP 更稳）"
		return 0
	fi
	die "落地机地址不合法: $1"
}

# -----------------------------------------------------------------------------
# 环境
# -----------------------------------------------------------------------------
need_root() {
	[ "$(id -u)" = "0" ] && return 0
	die "需要 root 权限，请用 root 运行（su - 后再执行）"
}

# 判断 $0 是不是一个真实脚本文件（sh -c / 管道执行时为假）
is_real_script() {
	case "$SELF" in
	'' | sh | */sh | /bin/busybox | /bin/dash) return 1 ;;
	esac
	[ -f "$SELF" ]
}

# 启动时统一处理提权：能 sudo 就自己重跑一次
# 注意不要用 sudo -E：Ubuntu/Debian 默认 sudoers 没有 SETENV，-E 会直接报错
escalate_if_needed() {
	[ "$(id -u)" = "0" ] && return 0
	if command -v sudo >/dev/null 2>&1 && is_real_script; then
		info "需要 root，正在通过 sudo 重新执行 ..."
		exec sudo sh "$SELF" "$@"
	fi
	die "需要 root 权限。请用 sudo 运行：sudo sh $0"
}

# -----------------------------------------------------------------------------
# 依赖预装（针对精简系统：先补包、先加载内核模块，再动规则）
# -----------------------------------------------------------------------------
detect_pkg() {
	if command -v apk >/dev/null 2>&1; then PKG=apk
	elif command -v apt-get >/dev/null 2>&1; then PKG=apt
	elif command -v dnf >/dev/null 2>&1; then PKG=dnf
	elif command -v yum >/dev/null 2>&1; then PKG=yum
	elif command -v opkg >/dev/null 2>&1; then PKG=opkg
	elif command -v microdnf >/dev/null 2>&1; then PKG=microdnf
	else PKG=""; fi
}

pkg_update() {
	case "$PKG" in
	apk) apk update >/dev/null 2>&1 ;;
	apt) apt-get update >/dev/null 2>&1 ;;
	dnf) dnf makecache >/dev/null 2>&1 ;;
	yum) yum makecache >/dev/null 2>&1 ;;
	microdnf) microdnf makecache >/dev/null 2>&1 ;;
	opkg) opkg update >/dev/null 2>&1 ;;
	esac
}

pkg_install() { # 包名...
	[ -n "$PKG" ] && [ $# -gt 0 ] || return 1
	case "$PKG" in
	apk) apk add --no-cache "$@" >/dev/null 2>&1 ;;
	apt) DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" >/dev/null 2>&1 ;;
	dnf) dnf install -y "$@" >/dev/null 2>&1 ;;
	yum) yum install -y "$@" >/dev/null 2>&1 ;;
	microdnf) microdnf install -y "$@" >/dev/null 2>&1 ;;
	opkg) opkg update >/dev/null 2>&1; opkg install "$@" >/dev/null 2>&1 ;;
	*) return 1 ;;
	esac
}

# 先直接装；失败（apt 索引太旧是常见原因）就刷新索引再试一次
pkg_ensure() { # 包名...
	[ -n "$PKG" ] && [ $# -gt 0 ] || return 1
	pkg_install "$@" && return 0
	pkg_update
	pkg_install "$@" && return 0
	return 1
}

# 精简系统常常没自动带出 iptables 的内核模块，显式 modprobe 一遍
load_modules() {
	command -v modprobe >/dev/null 2>&1 || return 0
	for _lm in ip_tables iptable_filter iptable_nat nf_nat nf_conntrack \
		nf_nat_masquerade_ipv4 xt_MASQUERADE xt_comment xt_conntrack; do
		modprobe "$_lm" >/dev/null 2>&1 || true
	done
	return 0
}

tmpfile() {
	_tf=
	if command -v mktemp >/dev/null 2>&1; then
		_tf=$(mktemp 2>/dev/null)
	fi
	[ -n "$_tf" ] || _tf="${TMPDIR:-/tmp}/.portfwd.$$.$(date +%s 2>/dev/null)"
	printf '%s\n' "$_tf"
}

ensure_iptables() {
	[ -n "$PKG" ] || detect_pkg
	if [ "$MODULES_LOADED" != "1" ]; then
		load_modules
		MODULES_LOADED=1
	fi
	if ! command -v "$IPT" >/dev/null 2>&1; then
		info "未检测到 iptables，正在安装 ..."
		pkg_ensure iptables || pkg_ensure iptables-nft || true
	fi
	command -v "$IPT" >/dev/null 2>&1 ||
		die "装不上 iptables（包管理器: ${PKG:-未识别}）。请手动安装后重试"

	# nat 表能不能真的用：精简系统常缺 iptable_nat，或在容器里没权限
	if ! $IPT -t nat -L -n >/dev/null 2>&1; then
		for _alt in iptables-legacy iptables-nft; do
			if command -v "$_alt" >/dev/null 2>&1 && $_alt -t nat -L -n >/dev/null 2>&1; then
				IPT=$_alt
				warn "默认 iptables 后端的 nat 表不可用，已切换为 $_alt"
				break
			fi
		done
	fi
	$IPT -t nat -L -n >/dev/null 2>&1 || die "iptables 的 nat 表不可用：
  - 容器里需要 --cap-add NET_ADMIN --cap-add NET_RAW
  - 精简系统可能缺内核模块，手动执行：
      modprobe ip_tables iptable_nat nf_nat xt_MASQUERADE xt_comment
  - Alpine:     apk add iptables
  - Debian/Ubuntu: apt-get install -y iptables"
	ok "iptables 可用（$IPT）"

	command -v iptables-save >/dev/null 2>&1 ||
		warn "没有 iptables-save，改用「开机钩子重放」来持久化（不影响功能）"
}

# 精简 busybox 可能裁掉了 awk/sed/cut 等 applet，逐个补
ensure_tools() {
	_et_miss=""
	for _et_c in awk sed grep head cut sort tr mktemp; do
		command -v "$_et_c" >/dev/null 2>&1 || _et_miss="$_et_miss $_et_c"
	done
	if [ -z "$_et_miss" ]; then
		ok "基础命令齐全"
		return 0
	fi
	info "缺少命令:$_et_miss  — 尝试补装 ..."
	case "$PKG" in
	apk) pkg_ensure busybox coreutils gawk ;;
	apt) pkg_install coreutils gawk procps ;;
	dnf | yum) pkg_install coreutils gawk procps-ng ;;
	microdnf) pkg_install coreutils gawk procps-ng ;;
	opkg) pkg_install coreutils busybox ;;
	esac
	_et_miss=""
	for _et_c in awk sed grep head cut sort tr mktemp; do
		command -v "$_et_c" >/dev/null 2>&1 || _et_miss="$_et_miss $_et_c"
	done
	[ -z "$_et_miss" ] || die "仍缺少命令:$_et_miss（请手动装 busybox 或 coreutils+gawk）"
	ok "基础命令已补齐"
}

enable_forward() {
	if command -v sysctl >/dev/null 2>&1; then
		sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
	fi
	# 没有 sysctl 也照样能开：直接写 /proc
	if [ "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)" != "1" ]; then
		echo 1 >/proc/sys/net/ipv4/ip_forward 2>/dev/null
	fi
	if [ "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)" != "1" ]; then
		warn "内核转发打不开。若在容器里，启动容器时需加："
		warn "    --cap-add NET_ADMIN --cap-add NET_RAW --sysctl net.ipv4.ip_forward=1"
		return 1
	fi
	if [ -f /etc/sysctl.conf ]; then
		if grep -qE '^[[:space:]]*net\.ipv4\.ip_forward' /etc/sysctl.conf; then
			sed -i 's/^[[:space:]]*net\.ipv4\.ip_forward.*/net.ipv4.ip_forward = 1/' /etc/sysctl.conf
		else
			echo 'net.ipv4.ip_forward = 1' >>/etc/sysctl.conf
		fi
	else
		printf 'net.ipv4.ip_forward = 1\n' >/etc/sysctl.conf 2>/dev/null
	fi
	if [ -d /etc/sysctl.d ]; then
		printf 'net.ipv4.ip_forward = 1\n' >/etc/sysctl.d/99-portfwd.conf 2>/dev/null || true
	fi
	ok "内核 IPv4 转发已开启并持久化"
	return 0
}

# 探测是否支持 -m comment（极少数精简内核没有 xt_comment）
# 必须直接调用，不能放进 $( )，否则赋值会丢在子 shell 里
probe_comment() {
	COMMENT_OK=0
	$IPT -t nat -N PFWD_PROBE >/dev/null 2>&1 || true
	if $IPT -t nat -A PFWD_PROBE -m comment --comment pfwdprobe -j RETURN >/dev/null 2>&1; then
		COMMENT_OK=1
	fi
	$IPT -t nat -F PFWD_PROBE >/dev/null 2>&1 || true
	$IPT -t nat -X PFWD_PROBE >/dev/null 2>&1 || true
	[ "$COMMENT_OK" = "1" ] || warn "内核不支持 iptables comment 标记，改用无标记模式（仍然幂等）"
}

# -----------------------------------------------------------------------------
# 规则引擎（table / chain 通用）
# -----------------------------------------------------------------------------
# 统一约定：TARGET 单独作为第 4 个参数，-m comment 永远插在 -j 之前。
# 这是 iptables 的规范顺序；写成 "-j DNAT ... -m comment" 在部分精简内核上会解析失败。
rule_add() { # table chain tag "target [target-opts]" match...
	ra_t=$1; ra_c=$2; ra_g=$3; ra_j=$4; shift 4
	if [ "$COMMENT_OK" = "1" ]; then
		$IPT -t "$ra_t" -C "$ra_c" "$@" -m comment --comment "$ra_g" -j $ra_j >/dev/null 2>&1 && return 0
		$IPT -t "$ra_t" -A "$ra_c" "$@" -m comment --comment "$ra_g" -j $ra_j 2>/dev/null && return 0
	else
		$IPT -t "$ra_t" -C "$ra_c" "$@" -j $ra_j >/dev/null 2>&1 && return 0
		$IPT -t "$ra_t" -A "$ra_c" "$@" -j $ra_j 2>/dev/null && return 0
	fi
	warn "添加规则失败: -t $ra_t -A $ra_c $* -j $ra_j"
	return 1
}

# 删掉“完全相同但不带标记”的规则（清理手工加的），删到干净
rule_del_plain() { # table chain "target [opts]" match...
	rd_t=$1; rd_c=$2; rd_j=$3; shift 3
	rd_i=0
	while $IPT -t "$rd_t" -C "$rd_c" "$@" -j $rd_j >/dev/null 2>&1; do
		$IPT -t "$rd_t" -D "$rd_c" "$@" -j $rd_j >/dev/null 2>&1 || break
		rd_i=$((rd_i + 1))
		[ "$rd_i" -ge 20 ] && break
	done
}

# 清掉带 portfwd: 标记的规则；不带参数时只处理 NAT 两条链
# （filter/INPUT 上的 open-port 放行规则不该被 apply 顺手删掉）
# 实现上按规则序号删除，不依赖 sed/xargs —— 精简 busybox 里这些 applet 可能没编译进去
del_tagged() {
	[ $# -gt 0 ] || set -- nat:PREROUTING nat:POSTROUTING filter:FORWARD
	for _dt_spec in "$@"; do
		_dt_tbl=${_dt_spec%%:*}
		_dt_chn=${_dt_spec##*:}
		_dt_i=0
		while :; do
			_dt_n=$($IPT -t "$_dt_tbl" -S "$_dt_chn" 2>/dev/null | grep '^-A' | grep -nF 'portfwd:' | head -n 1 | cut -d: -f1)
			[ -n "$_dt_n" ] || break
			_dt_i=$((_dt_i + 1))
			[ "$_dt_i" -gt 300 ] && break
			$IPT -t "$_dt_tbl" -D "$_dt_chn" "$_dt_n" >/dev/null 2>&1 || break
		done
	done
}

rule_exists() { # table chain tag "target [target-opts]" match...
	re_t=$1; re_c=$2; re_g=$3; re_j=$4; shift 4
	if [ "$COMMENT_OK" = "1" ]; then
		$IPT -t "$re_t" -C "$re_c" "$@" -m comment --comment "$re_g" -j $re_j >/dev/null 2>&1
	else
		$IPT -t "$re_t" -C "$re_c" "$@" -j $re_j >/dev/null 2>&1
	fi
}

# 给一条映射铺 4 条规则
apply_entry() { # L R P
	ae_l=$1; ae_r=$2; ae_p=$3; ae_d="$ae_r:$ae_p"
	for ae_proto in tcp udp; do
		rule_del_plain nat PREROUTING "DNAT --to-destination $ae_d" -p "$ae_proto" --dport "$ae_l"
		rule_del_plain nat POSTROUTING "MASQUERADE" -p "$ae_proto" -d "$ae_r" --dport "$ae_p"
		rule_add nat PREROUTING "portfwd:dnat:$ae_proto:$ae_l:$ae_d" "DNAT --to-destination $ae_d" \
			-p "$ae_proto" --dport "$ae_l"
		rule_add nat POSTROUTING "portfwd:masq:$ae_proto:$ae_r:$ae_p" "MASQUERADE" \
			-p "$ae_proto" -d "$ae_r" --dport "$ae_p"
		# FORWARD 放行：ufw 默认「routed: deny」时，包在 FORWARD 链上会被丢，
		# 表现为 DNAT 计数在涨、MASQUERADE 计数为 0。这里显式放行两个方向。
		rule_add filter FORWARD "portfwd:fwd:$ae_proto:$ae_l:$ae_d" "ACCEPT" \
			-d "$ae_r" -p "$ae_proto" --dport "$ae_p"
		rule_add filter FORWARD "portfwd:fwd:$ae_proto:$ae_l:$ae_d" "ACCEPT" \
			-s "$ae_r" -p "$ae_proto" --sport "$ae_p"
	done
}

verify_entry() { # L R P
	ve_l=$1; ve_r=$2; ve_p=$3; ve_d="$ve_r:$ve_p"; ve_bad=0
	for ve_proto in tcp udp; do
		rule_exists nat PREROUTING "portfwd:dnat:$ve_proto:$ve_l:$ve_d" "DNAT --to-destination $ve_d" \
			-p "$ve_proto" --dport "$ve_l" \
			|| { warn "缺少 DNAT: $ve_proto 本地$ve_l -> $ve_d"; ve_bad=1; }
		rule_exists nat POSTROUTING "portfwd:masq:$ve_proto:$ve_r:$ve_p" "MASQUERADE" \
			-p "$ve_proto" -d "$ve_r" --dport "$ve_p" \
			|| { warn "缺少 MASQUERADE: $ve_proto -> $ve_d"; ve_bad=1; }
		rule_exists filter FORWARD "portfwd:fwd:$ve_proto:$ve_l:$ve_d" "ACCEPT" \
			-d "$ve_r" -p "$ve_proto" --dport "$ve_p" \
			|| { warn "缺少 FORWARD 放行(out): $ve_proto -> $ve_d"; ve_bad=1; }
		rule_exists filter FORWARD "portfwd:fwd:$ve_proto:$ve_l:$ve_d" "ACCEPT" \
			-s "$ve_r" -p "$ve_proto" --sport "$ve_p" \
			|| { warn "缺少 FORWARD 放行(in): $ve_proto <- $ve_d"; ve_bad=1; }
	done
	return "$ve_bad"
}

# 按 /etc/portfwd.conf 全量重放
apply_all() {
	del_tagged
	aa_n=0
	while read -r aa_l aa_r aa_p _; do
		[ -n "${aa_l:-}" ] || continue
		[ -n "${aa_p:-}" ] || { warn "配置行不完整，跳过: $aa_l $aa_r"; continue; }
		apply_entry "$aa_l" "$aa_r" "$aa_p"
		aa_n=$((aa_n + 1))
	done <<EOF
$(conf_read)
EOF

	aa_bad=0
	while read -r aa_l aa_r aa_p _; do
		[ -n "${aa_l:-}" ] || continue
		verify_entry "$aa_l" "$aa_r" "$aa_p" || aa_bad=1
	done <<EOF
$(conf_read)
EOF
	[ "$aa_bad" = "0" ] || die "有规则没铺上，请看上面的 [!] 提示"
	ok "已写入 $aa_n 条映射（每条同时含 TCP 与 UDP）"
	check_forward_policy
	return 0
}

check_forward_policy() {
	_fw=$($IPT -S FORWARD 2>/dev/null | awk '$1 == "-P" { print $2; exit }')
	if [ "${_fw:-}" = "DROP" ]; then
		ok "FORWARD 默认策略为 DROP，已通过 portfwd: 规则显式放行本项目的转发流量"
	fi
}

# -----------------------------------------------------------------------------
# 配置读写
# -----------------------------------------------------------------------------
conf_read() {
	[ -f "$CONF" ] || return 0
	awk '$1 ~ /^#/ || NF < 3 { next } { print $1, $2, $3 }' "$CONF"
}

conf_has() {
	conf_read | awk -v l="$1" '($1 "") == (l "") { f = 1 } END { exit(f ? 0 : 1) }'
}

conf_put() { # L R P
	cp_l=$1; cp_r=$2; cp_p=$3
	cp_t=$(tmpfile)
	{
		conf_read | awk -v l="$cp_l" '($1 "") != (l "")'
		printf '%s %s %s\n' "$cp_l" "$cp_r" "$cp_p"
	} >"$cp_t"
	{
		echo "$CONF_HEAD"
		sort -n -k1,1 "$cp_t"
	} >"$CONF"
	rm -f "$cp_t"
}

conf_drop() { # L
	cd_t=$(tmpfile)
	conf_read | awk -v l="$1" '($1 "") != (l "")' >"$cd_t"
	{
		echo "$CONF_HEAD"
		sort -n -k1,1 "$cd_t"
	} >"$CONF"
	rm -f "$cd_t"
}

# -----------------------------------------------------------------------------
# 随机端口
# -----------------------------------------------------------------------------
rand_port() {
	rp_r=
	if [ -r /dev/urandom ]; then
		rp_r=$(od -An -N2 -tu2 /dev/urandom 2>/dev/null | tr -dc '0-9')
	fi
	case "$rp_r" in '' | *[!0-9]*) rp_r=$(awk 'BEGIN { srand(); printf "%d", int(rand() * 55536) }') ;; esac
	printf '%s\n' "$((10000 + rp_r % 55536))"
}

port_listening() {
	if command -v ss >/dev/null 2>&1; then
		ss -lntu 2>/dev/null | awk -v p="$1" '$5 ~ (":" p "$") { f = 1 } END { exit(f ? 0 : 1) }'
	elif command -v netstat >/dev/null 2>&1; then
		netstat -lntu 2>/dev/null | awk -v p="$1" '$4 ~ (":" p "$") { f = 1 } END { exit(f ? 0 : 1) }'
	else
		return 1
	fi
}

rand_free_port() {
	rfp_i=0
	while [ "$rfp_i" -lt 50 ]; do
		rfp_p=$(rand_port)
		if ! conf_has "$rfp_p" && ! port_listening "$rfp_p"; then
			printf '%s\n' "$rfp_p"
			return 0
		fi
		rfp_i=$((rfp_i + 1))
	done
	printf '%s\n' "$(rand_port)"
}

# -----------------------------------------------------------------------------
# 交互
# -----------------------------------------------------------------------------
ensure_tty() {
	[ -t 0 ] && return 0
	die "需要交互输入，但当前标准输入不是终端。
请先把脚本下载再运行，例如：
    wget -qO /tmp/portfwd.sh <脚本地址> && sh /tmp/portfwd.sh
或直接带参数运行（无需交互）：
    sh portfwd.sh add -l 10888 -r 1.2.3.4 -p 443 -y"
}

ask() { # $1=提示  $2=默认值；结果放 ANSWER
	ask_q=$1; ask_d=$2
	while :; do
		if [ -n "$ask_d" ]; then
			printf '    %s [%s]: ' "$ask_q" "$ask_d"
		else
			printf '    %s: ' "$ask_q"
		fi
		if IFS= read -r ANSWER; then :; else printf '\n'; die "输入被中断"; fi
		[ -z "$ANSWER" ] && ANSWER=$ask_d
		[ -n "$ANSWER" ] && return 0
		warn "不能为空，请重新输入"
	done
}

ask_port() { # $1=提示  $2=默认
	ask_port_d=$2
	while :; do
		ask "$1" "$ask_port_d"
		is_port "$ANSWER" && return 0
		warn "端口必须是 1-65535 的数字"
	done
}

ask_target() {
	while :; do
		ask "$1" "$2"
		if is_ipv4 "$ANSWER"; then return 0; fi
		if is_hostname "$ANSWER"; then
			warn "这看起来是域名，iptables 会自己解析；如果解析不了建议直接填 IPv4"
			return 0
		fi
		warn "地址不合法，示例：1.2.3.4"
	done
}

confirm() { # $1=提示 $2=默认(y/n，缺省 y)
	[ "$ASSUME_YES" = 1 ] && return 0
	cf_d=${2:-y}
	if [ "$cf_d" = "n" ]; then
		cf_hint="[y/N]"
	else
		cf_hint="[Y/n]"
	fi
	printf '    %s %s: ' "$1" "$cf_hint"
	cf_a=
	if IFS= read -r cf_a; then :; else
		printf '\n' >&2
		warn "标准输入已结束；非交互运行请加 -y"
		return 1
	fi
	if [ -z "$cf_a" ]; then
		[ "$cf_d" = "n" ] && return 1
		return 0
	fi
	case "$cf_a" in y | Y | yes | YES | Yes) return 0 ;; esac
	return 1
}

# -----------------------------------------------------------------------------
# 持久化
# -----------------------------------------------------------------------------
copy_self() {
	case "$SELF" in
	/usr/local/sbin/portfwd) return 0 ;;
	esac
	is_real_script || return 1
	mkdir -p /usr/local/sbin 2>/dev/null || return 1
	cp "$SELF" /usr/local/sbin/portfwd 2>/dev/null || return 1
	chmod 0755 /usr/local/sbin/portfwd 2>/dev/null || return 1
	return 0
}

write_boot_hook() {
	[ -d /etc/local.d ] || return 1
	cat >/etc/local.d/portfwd.start <<'EOS'
#!/bin/sh
# 由 portfwd.sh 生成：开机重放 /etc/portfwd.conf 与 /etc/portfwd.open
if [ -x /usr/local/sbin/portfwd ]; then
	/usr/local/sbin/portfwd boot >/dev/null 2>&1
else
	sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
	[ "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)" = "1" ] || echo 1 >/proc/sys/net/ipv4/ip_forward 2>/dev/null
fi
EOS
	chmod 0755 /etc/local.d/portfwd.start 2>/dev/null
	return 0
}

# systemd（Ubuntu / Debian / CentOS 等）
write_systemd_unit() {
	[ -d /etc/systemd/system ] || return 1
	cat >/etc/systemd/system/portfwd.service <<'EOS'
[Unit]
Description=portfwd NAT forwarding rules
Documentation=https://github.com/louwailou777/alpine-portfwd
After=local-fs.target ufw.service
Before=network.target
Wants=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/portfwd boot
ExecReload=/usr/local/sbin/portfwd apply
TimeoutStartSec=60

[Install]
WantedBy=multi-user.target
EOS
	chmod 0644 /etc/systemd/system/portfwd.service 2>/dev/null
	return 0
}

persist() {
	# 1) 保存当前规则快照（OpenRC 与兜底恢复都用得上）
	if [ -x /etc/init.d/iptables ]; then
		/etc/init.d/iptables save >/dev/null 2>&1
	fi
	if command -v iptables-save >/dev/null 2>&1; then
		mkdir -p /etc/iptables 2>/dev/null
		iptables-save >/etc/iptables/rules-save 2>/dev/null ||
			warn "规则写入 /etc/iptables/rules-save 失败"
	fi
	if command -v netfilter-persistent >/dev/null 2>&1; then
		netfilter-persistent save >/dev/null 2>&1 && ok "规则已保存（netfilter-persistent）"
	fi

	# 2) 开机自启：按 init 系统分别处理
	if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
		if copy_self; then
			ok "脚本已安装到 /usr/local/sbin/portfwd"
			if write_systemd_unit; then
				systemctl daemon-reload >/dev/null 2>&1
				if systemctl enable portfwd.service >/dev/null 2>&1; then
					ok "systemd 服务已启用（portfwd.service）"
				else
					warn "systemctl enable portfwd.service 失败"
				fi
			else
				warn "写入 /etc/systemd/system/portfwd.service 失败"
			fi
			ok "规则已保存，重启自动恢复"
		else
			warn "脚本没能装到 /usr/local/sbin/portfwd，跳过开机自启"
			warn "如需重启后仍生效，请把它放到固定路径后执行：portfwd.sh save"
		fi
	elif command -v rc-update >/dev/null 2>&1 && [ -d /run/openrc ]; then
		rc-update add iptables default >/dev/null 2>&1
		if copy_self; then
			ok "脚本已安装到 /usr/local/sbin/portfwd"
		else
			warn "脚本没能装到 /usr/local/sbin/portfwd，开机改由 iptables 服务恢复规则"
		fi
		if write_boot_hook; then
			rc-update add local default >/dev/null 2>&1
			ok "已装开机钩子 /etc/local.d/portfwd.start"
		fi
		ok "规则已保存，重启自动恢复"
	else
		warn "未检测到 systemd / OpenRC，跳过开机自启（容器请在启动命令里执行本脚本）"
	fi
}

# -----------------------------------------------------------------------------
# 线路质量预检：先 ping 看延迟和丢包，再决定值不值得转发
# 判定阈值都放在这里，想收紧/放宽改这几个数就行
# -----------------------------------------------------------------------------
P_COUNT=${P_COUNT:-10}
P_GOOD_MS=60
P_OK_MS=120
P_BAD_MS=200
P_LOSS_OK=2
P_LOSS_BAD=10
NO_PROBE=0
PROBE_IP=""
PROBE_PORT=""
PR_LOSS=100
PR_AVG=""
PR_MIN=""
PR_MAX=""
PR_OK=0
PR_VERDICT=9

ensure_ping() {
	command -v ping >/dev/null 2>&1 && return 0
	[ -n "$PKG" ] || detect_pkg
	info "未检测到 ping，尝试安装 ..."
	case "$PKG" in
	apk) pkg_ensure iputils ;;
	apt) pkg_ensure iputils-ping ;;
	dnf | yum | microdnf) pkg_install iputils ;;
	opkg) pkg_install iputils-ping ;;
	esac
	command -v ping >/dev/null 2>&1
}

# 跑 ping 并把 丢包率 / min-avg-max 解析到 PR_* 变量
probe_line() { # ip [次数] [安静模式 0/1]
	pl_ip=$1
	pl_cnt=${2:-$P_COUNT}
	pl_q=${3:-0}
	PR_LOSS=100
	PR_AVG=""
	PR_MIN=""
	PR_MAX=""
	PR_OK=0

	ensure_ping || true
	if ! command -v ping >/dev/null 2>&1; then
		[ "$pl_q" = "1" ] || warn "系统没有 ping，跳过延迟/丢包检测"
		return 1
	fi

	pl_log=$(tmpfile)
	PR_COUNT=$pl_cnt
	if [ "$pl_q" != "1" ]; then
		out "    正在 ping $pl_ip 共 $pl_cnt 次（预计 $pl_cnt-$((pl_cnt * 2)) 秒）..."
	fi
	pl_to=""
	if command -v timeout >/dev/null 2>&1; then
		pl_to="timeout $((pl_cnt * 3 + 5))"
	fi
	if [ "$pl_q" = "1" ] || ! command -v tee >/dev/null 2>&1; then
		$pl_to ping -c "$pl_cnt" -W 2 "$pl_ip" >"$pl_log" 2>&1
		[ "$pl_q" = "1" ] || cat "$pl_log"
	else
		$pl_to ping -c "$pl_cnt" -W 2 "$pl_ip" 2>&1 | tee "$pl_log"
	fi

	# 丢包率："10 packets transmitted, 9 received, 10% packet loss"
	pl_got=0
	pl_l=$(grep 'packet loss' "$pl_log" 2>/dev/null | tail -n 1)
	if [ -n "$pl_l" ]; then
		pl_v=$(printf '%s\n' "$pl_l" | sed -n 's/.*[^0-9]\([0-9][0-9]*\)% packet loss.*/\1/p')
		if [ -n "$pl_v" ]; then
			PR_LOSS=$pl_v
			pl_got=1
		fi
	fi

	# 延迟："rtt min/avg/max/mdev = 1.1/2.2/3.3/0.4 ms"（busybox 是 round-trip min/avg/max）
	pl_s=$(grep 'min/avg/max' "$pl_log" 2>/dev/null | tail -n 1)
	if [ -n "$pl_s" ]; then
		pl_s=$(printf '%s\n' "$pl_s" | sed 's/.*= *//')
		PR_MIN=${pl_s%%/*}
		pl_r=${pl_s#*/}
		PR_AVG=${pl_r%%/*}
		pl_r=${pl_r#*/}
		PR_MAX=${pl_r%%/*}
	fi
	rm -f "$pl_log"
	# 全部丢包时 ping 只给丢包率、不给 rtt，这种也必须算“测到了”，否则会被误判成“未知”
	PR_OK=$pl_got
	return 0
}

# 0 优秀 / 1 良好 / 2 一般 / 3 偏高 / 4 严重 / 9 无法判断
judge_line() {
	if [ "$PR_OK" != "1" ]; then
		printf '9\n'
		return 0
	fi
	awk -v loss="${PR_LOSS:-100}" -v avg="${PR_AVG:-0}" \
		-v good="$P_GOOD_MS" -v ok="$P_OK_MS" -v bad="$P_BAD_MS" \
		-v lok="$P_LOSS_OK" -v lbad="$P_LOSS_BAD" 'BEGIN {
		if (loss >= 50) { print 4; exit }
		if (loss >= lbad || avg >= bad) { print 3; exit }
		if (loss > lok || avg >= ok) { print 2; exit }
		if (avg >= good) { print 1; exit }
		print 0
	}'
}

probe_report() {
	PR_VERDICT=$(judge_line)
	PR_AVG_SHOW=${PR_AVG:-无回包}
	out ""
	out "    -------------------- 线路检测 --------------------"
	if [ -n "$PROBE_PORT" ]; then
		out "      落地机           : $PROBE_IP:$PROBE_PORT"
	else
		out "      落地机           : $PROBE_IP"
	fi
	if [ "$PR_OK" = "1" ]; then
		out "      ping             : 共 ${PR_COUNT:-$P_COUNT} 次，丢包 ${PR_LOSS}%"
		if [ -n "$PR_AVG" ]; then
			out "      延迟 min/avg/max : ${PR_MIN}/${PR_AVG}/${PR_MAX} ms"
		else
			out "      延迟             : 全部超时，没有回包"
		fi
	else
		out "      ping             : 不可用（没有 ping 命令或执行失败）"
	fi
	case "$PR_VERDICT" in
	0) out "      结论             : [优秀] 平均 ${PR_AVG_SHOW} ms，非常适合转发" ;;
	1) out "      结论             : [良好] 平均 ${PR_AVG_SHOW} ms，适合转发" ;;
	2) out "      结论             : [一般] 平均 ${PR_AVG_SHOW} ms、丢包 ${PR_LOSS}%，可以转发" ;;
	3) out "      结论             : [偏高] 延迟或丢包偏大，不建议用于实时业务" ;;
	4) out "      结论             : [严重] 延迟/丢包严重，不建议转发，建议换落地机" ;;
	*) out "      结论             : [未知] 无法判断线路质量" ;;
	esac
	out "    --------------------------------------------------"
	if [ "$PR_OK" = "1" ] && [ "$PR_LOSS" = "100" ]; then
		out "    注：100% 丢包常见于落地机屏蔽 ICMP，不代表 TCP 不通；可继续，后面用 test 复核"
	fi
	case "$PR_VERDICT" in
	3 | 4) loss_path ;;
	esac
	return 0
}

# 丢包/高延迟时再追一下路径，看看问题出在哪一跳
loss_path() {
	if command -v mtr >/dev/null 2>&1; then
		out ""
		out "    逐跳丢包（mtr -c 5）："
		mtr -r -c 5 -n "$PROBE_IP" 2>/dev/null | sed 's/^/      /'
	elif command -v traceroute >/dev/null 2>&1; then
		out ""
		out "    路径追踪（traceroute）："
		traceroute -n -w 1 -q 1 -m 12 "$PROBE_IP" 2>/dev/null | sed 's/^/      /'
	else
		out "    提示：装 mtr 可看逐跳丢包（apk add mtr）"
	fi
}

# 检测 + 结论 + 询问要不要继续；不想测就 --no-probe
probe_gate() { # ip
	PROBE_IP=$1
	[ "$NO_PROBE" = "1" ] && return 0
	probe_line "$1" "$P_COUNT" 0
	probe_report
	[ "$ASSUME_YES" = "1" ] && return 0
	[ -t 0 ] || return 0
	out ""
	case "$PR_VERDICT" in
	2 | 3 | 4)
		confirm "线路质量不理想，仍然继续配置转发吗？" n || die "已退出，没有做任何修改"
		;;
	*)
		confirm "是否继续配置转发？" y || die "已退出，没有做任何修改"
		;;
	esac
	return 0
}

# -----------------------------------------------------------------------------
# 向导
# -----------------------------------------------------------------------------
banner() {
	[ "$QUIET" = 1 ] && return 0
	cat <<'EOF'
==============================================================
        端口转发一键配置  ·  转发机(NAT) → 落地机
==============================================================
EOF
}

bootstrap() {
	need_root
	ensure_iptables
	ensure_tools
	enable_forward || warn "ip_forward 没打开，转发不会生效"
	probe_comment
}

# 结果变量：W_L / W_R / W_P
wizard() {
	banner
	ensure_tty

	out ""
	out "[1/5] 落地机地址与端口"
	out "      落地机 IP，例：1.2.3.4"
	ask_target "落地机 IP" ""
	W_R=$ANSWER
	out "      落地机上真正跑服务的端口（不是本机端口）"
	out "      常用：443 / 80 / 8443 / 8080"
	ask_port "落地机端口（必填，不能回车跳过）" ""
	W_P=$ANSWER

	out ""
	out "[2/5] 线路质量检测"
	out "      先测本机到落地机的延迟和丢包，确认值得转发再往下走"
	PROBE_PORT=$W_P
	probe_gate "$W_R"

	out ""
	out "[3/5] 环境与依赖检查"
	bootstrap

	out ""
	out "[4/5] 转发机端口（本机 NAT 端口）"
	out "      这是转发机上的端口，路由器/安全组会把外网端口指向它"
	W_L=$(rand_free_port)
	out "      已生成随机可用端口：$W_L"
	ask_port "直接回车使用随机端口，或输入其他端口" "$W_L"
	W_L=$ANSWER

	out ""
	out "[5/5] 确认并写入"
	summary
	confirm "确认写入？" || die "已取消，没有做任何修改"

	commit
	return 0
}

summary() {
	out "      ------------------------------------------------"
	out "        转发机本地端口 : $W_L   (TCP + UDP)"
	out "        落地机         : $W_R:$W_P"
	if [ "$PR_OK" = "1" ]; then
		out "        线路质量       : 丢包 ${PR_LOSS}%，平均 ${PR_AVG_SHOW} ms"
	fi
	out "        内核转发       : 已开启"
	out "        持久化         : 保存规则 + 开机自启"
	out "      ------------------------------------------------"
}

commit() {
	conf_put "$W_L" "$W_R" "$W_P"
	apply_all
	persist
	maybe_open_port
	remind
}

# 记录需要持久化的放行端口（重启后由 boot 重放）
record_open_port() {
	for ro_p in "$@"; do
		is_port "$ro_p" || continue
		if [ ! -f "$OPEN_FILE" ] || ! grep -qxF "$ro_p" "$OPEN_FILE" 2>/dev/null; then
			printf '%s\n' "$ro_p" >>"$OPEN_FILE" 2>/dev/null
		fi
	done
}

open_port_now() { # 端口...
	for op_p in "$@"; do
		is_port "$op_p" || return 1
		rule_add filter INPUT "portfwd:open:$op_p" "ACCEPT" -p tcp --dport "$op_p"
		rule_add filter INPUT "portfwd:open:$op_p" "ACCEPT" -p udp --dport "$op_p"
	done
	rule_add filter INPUT "portfwd:ct" "ACCEPT" -m conntrack --ctstate RELATED,ESTABLISHED >/dev/null 2>&1
	record_open_port "$@"
	if command -v iptables-save >/dev/null 2>&1; then
		iptables-save >/etc/iptables/rules-save 2>/dev/null
	fi
	ok "已放行本机 INPUT 端口: $*"
	return 0
}

# 只有本机 INPUT 真的设了拦截时才问，默认不放行
maybe_open_port() {
	[ "$ASSUME_YES" = 1 ] && return 0
	[ -t 0 ] || return 0
	mo_pol=$($IPT -S INPUT 2>/dev/null | awk '$1 == "-P" { print $2; exit }')
	mo_cnt=$($IPT -S INPUT 2>/dev/null | grep -vc '^-P' 2>/dev/null)
	case "$mo_cnt" in '' | *[!0-9]*) mo_cnt=0 ;; esac
	if [ "${mo_pol:-ACCEPT}" = "ACCEPT" ] && [ "$mo_cnt" -eq 0 ]; then
		return 0
	fi
	out ""
	out "本机 INPUT 链有拦截策略（默认策略=${mo_pol:-?}，规则 $mo_cnt 条）"
	printf '    现在就在本机放行端口 %s 吗？[y/N]: ' "$W_L"
	mo_a=
	IFS= read -r mo_a || return 0
	case "$mo_a" in y | Y | yes | YES) ;; *) return 0 ;; esac
	open_port_now "$W_L"
}

remind() {
	pub_ip=$(detect_pubip)
	wan_hint=${pub_ip:-你的公网IP}
	out ""
	out "=============================================================="
	out " 写入完成。最后还需要你手动做 3 件事："
	out "=============================================================="
	out ""
	out " 1) 在【转发机】上把外网端口映射到本机 NAT 端口"
	out "    - 家用路由器：端口转发 / 虚拟服务器 里加一条"
	out "        外网端口 → 本机IP:${W_L}   (TCP + UDP)"
	out "    - 云服务器：安全组 / 防火墙 放行 ${W_L} (TCP+UDP)"
	out "      或直接放行你打算给客户端用的那个外网端口"
	out ""
	out " 2) 本机若开了防火墙，放行端口（上面已自动放行则忽略）："
	out "      portfwd.sh open-port ${W_L}"
	out "    （本机 iptables INPUT 默认 ACCEPT 时可不做）"
	out ""
	out " 3) 客户端参数："
	out "      地址：${wan_hint}"
	out "      端口：你映射出去的「外网端口」"
	out "            例：路由器把 443 → ${W_L}，客户端就填 443"
	out "      其余参数不变"
	out ""
	out " 验证： portfwd.sh test"
	out " 查看： portfwd.sh list"
	out "=============================================================="
}

detect_pubip() {
	dp_ip=
	if command -v wget >/dev/null 2>&1; then
		dp_ip=$(wget -q -T 5 -O - https://api.ipify.org 2>/dev/null)
	fi
	if [ -z "$dp_ip" ] && command -v curl >/dev/null 2>&1; then
		dp_ip=$(curl -fsS -m 5 https://api.ipify.org 2>/dev/null)
	fi
	case "$dp_ip" in '' | *[!0-9.]*) dp_ip= ;; esac
	if is_ipv4 "$dp_ip"; then
		printf '%s\n' "$dp_ip"
	fi
}

# -----------------------------------------------------------------------------
# 子命令
# -----------------------------------------------------------------------------
cmd_add() {
	add_l=; add_r=; add_p=
	while [ $# -gt 0 ]; do
		case "$1" in
		-l | --local-port) [ $# -ge 2 ] || die "-l 缺少端口参数"; add_l=$2; shift 2 ;;
		-r | --remote-ip) [ $# -ge 2 ] || die "-r 缺少 IP 参数"; add_r=$2; shift 2 ;;
		-p | --remote-port) [ $# -ge 2 ] || die "-p 缺少端口参数"; add_p=$2; shift 2 ;;
		-y | --yes) ASSUME_YES=1; shift ;;
		-q | --quiet) QUIET=1; shift ;;
		-h | --help) usage; return 0 ;;
		*=*)
			add_l=${1%%=*}; _eq=${1#*=}; add_r=${_eq%:*}; add_p=${_eq##*:}
			shift
			;;
		*) die "未知参数: $1（看下 portfwd.sh help）" ;;
		esac
	done

	# 落地 IP + 端口要先拿到：端口没有默认值，必须由你指定
	if [ -z "$add_r" ] || [ -z "$add_p" ]; then
		ensure_tty
		out ""
		out "[1/5] 落地机地址与端口"
		if [ -z "$add_r" ]; then
			ask_target "落地机 IP" ""
			add_r=$ANSWER
		fi
		if [ -z "$add_p" ]; then
			out "      落地机上真正跑服务的端口（常用 443 / 80 / 8443 / 8080）"
			ask_port "落地机端口（必填，不能回车跳过）" ""
			add_p=$ANSWER
		fi
	fi
	PROBE_PORT=$add_p
	probe_gate "$add_r"

	bootstrap

	if [ -z "$add_l" ]; then
		ensure_tty
		out ""
		out "[4/5] 转发机端口（本机 NAT 端口）"
		add_l=$(rand_free_port)
		out "      已生成随机可用端口：$add_l"
		ask_port "直接回车使用随机端口，或输入其他端口" "$add_l"
		add_l=$ANSWER
	fi

	is_port "$add_l" || die "本地端口不合法: $add_l"
	is_port "$add_p" || die "落地机端口不合法: $add_p"
	check_target "$add_r"

	old=$(conf_read | awk -v l="$add_l" '($1 "") == (l "") { print $2":"$3; exit }')
	if [ -n "$old" ] && [ "$old" != "$add_r:$add_p" ]; then
		warn "端口 $add_l 原有映射 $old，将被覆盖为 $add_r:$add_p"
	fi

	W_L=$add_l; W_R=$add_r; W_P=$add_p
	out ""
	summary
	confirm "确认写入？" || die "已取消，没有做任何修改"
	commit
	return 0
}

cmd_add_pos() { # [-y] [--no-probe] L R P [L R P ...]
	while [ $# -gt 0 ]; do
		case "$1" in
		-y | --yes) ASSUME_YES=1; shift ;;
		-q | --quiet) QUIET=1; shift ;;
		--no-probe) NO_PROBE=1; shift ;;
		*) break ;;
		esac
	done
	[ $# -ge 3 ] || die "参数不足：需要 <本地端口> <落地IP> <落地端口>"
	is_port "$1" || die "本地端口不合法: $1"
	is_port "$3" || die "落地机端口不合法: $3"
	check_target "$2"
	PROBE_PORT=$3
	probe_gate "$2"
	bootstrap
	while [ $# -ge 3 ]; do
		is_port "$1" || die "本地端口不合法: $1"
		is_port "$3" || die "落地机端口不合法: $3"
		check_target "$2"
		conf_put "$1" "$2" "$3"
		ok "已登记: 本地 $1 -> $2:$3"
		shift 3
	done
	apply_all
	persist
	W_L=$(conf_read | head -n 1 | awk '{ print $1 }')
	W_R=$(conf_read | head -n 1 | awk '{ print $2 }')
	W_P=$(conf_read | head -n 1 | awk '{ print $3 }')
	remind
	return 0
}

cmd_probe() {
	pp_ip=""
	while [ $# -gt 0 ]; do
		case "$1" in
		--probe-count)
			[ $# -ge 2 ] || die "--probe-count 缺少参数"
			P_COUNT=$2
			is_port "$P_COUNT" && [ "$P_COUNT" -le 100 ] ||
				die "--probe-count 需要 1-100 的数字"
			shift 2
			;;
		-*) shift ;;
		*) pp_ip=$1; shift ;;
		esac
	done
	if [ -z "$pp_ip" ]; then
		ensure_tty
		out ""
		out "[线路检测] 只测质量，不写任何规则"
		ask_target "落地机 IP" ""
		pp_ip=$ANSWER
	fi
	check_target "$pp_ip"
	PROBE_IP=$pp_ip
	probe_line "$pp_ip" "$P_COUNT" 0
	probe_report
	return 0
}

cmd_rm() {
	[ $# -gt 0 ] || die "用法: portfwd.sh rm <本地端口> [本地端口...]"
	need_root
	ensure_iptables
	probe_comment
	for rm_l in "$@"; do
		is_port "$rm_l" || die "本地端口不合法: $rm_l"
		if conf_has "$rm_l"; then
			conf_drop "$rm_l"
			ok "已删除端口 $rm_l 的配置"
		else
			warn "配置里没有端口 $rm_l"
		fi
	done
	apply_all
	persist
	return 0
}

cmd_apply() {
	while [ $# -gt 0 ]; do
		case "$1" in
		-q | --quiet) QUIET=1; shift ;;
		*) break ;;
		esac
	done
	need_root
	ensure_iptables
	enable_forward || true
	probe_comment
	apply_all
	return 0
}

# 开机入口：只按 /etc/portfwd.conf 与 /etc/portfwd.open 重放我们自己的规则。
# 刻意不还原整份 iptables-save 快照 —— 那会把 ufw / docker / fail2ban 等
# 动态维护的 filter 链覆盖掉，反而搞坏系统网络。
cmd_boot() {
	if [ -r "$OPEN_FILE" ]; then
		while read -r bo_p; do
			[ -n "$bo_p" ] || continue
			is_port "$bo_p" || continue
			open_port_now "$bo_p"
		done <"$OPEN_FILE"
	fi
	cmd_apply -q
}

cmd_list() {
	need_root
	ensure_iptables
	pub_ip=$(detect_pubip)
	echo "== 本机 =="
	echo "  公网 IP : ${pub_ip:-(探测失败，请自己查)}"
	echo "  转发开关: net.ipv4.ip_forward = $(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)"
	echo
	if [ -s "$CONF" ]; then
		echo "== 映射列表（$CONF）=="
		conf_read | while read -r ls_l ls_r ls_p _; do
			[ -n "${ls_l:-}" ] || continue
			printf '  本机 %-6s -> %s:%s   (TCP+UDP)\n' "$ls_l" "$ls_r" "$ls_p"
		done
	else
		echo "== 还没有任何映射（$CONF 为空或不存在）=="
	fi
	echo
	echo "== nat/PREROUTING =="
	$IPT -t nat -S PREROUTING 2>/dev/null | grep 'DNAT' || echo "  (无)"
	echo
	echo "== nat/POSTROUTING =="
	$IPT -t nat -S POSTROUTING 2>/dev/null | grep 'MASQUERADE' || echo "  (无)"
	return 0
}

cmd_test() {
	need_root
	ensure_iptables
	probe_comment
	echo "== 内核转发 =="
	echo "  ip_forward = $(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)"
	echo
	echo "== 规则检查 =="
	bad=0
	if conf_read | grep -q .; then
		while read -r ts_l ts_r ts_p _; do
			[ -n "${ts_l:-}" ] || continue
			if verify_entry "$ts_l" "$ts_r" "$ts_p"; then
				echo "  [OK] 本机 $ts_l -> $ts_r:$ts_p"
			else
				echo "  [!!] 本机 $ts_l -> $ts_r:$ts_p 规则不完整"
				bad=1
			fi
		done <<EOF
$(conf_read)
EOF
	else
		echo "  (没有配置)"
	fi
	echo
	echo "== 落地机连通性 =="
	if conf_read | grep -q .; then
		while read -r tc_l tc_r tc_p _; do
			[ -n "${tc_l:-}" ] || continue
			if command -v ping >/dev/null 2>&1; then
				probe_line "$tc_r" 5 1
				if [ "$PR_OK" = "1" ]; then
					printf '  [ping] %-16s 丢包 %s%%，平均 %s ms\n' "$tc_r" "$PR_LOSS" "$PR_AVG"
				else
					printf '  [ping] %-16s 无响应\n' "$tc_r"
				fi
			fi
			if command -v nc >/dev/null 2>&1; then
				if nc -z -w 3 "$tc_r" "$tc_p" 2>/dev/null; then
					printf '  [tcp ] %-16s:%s 可连通\n' "$tc_r" "$tc_p"
				else
					printf '  [tcp ] %-16s:%s 连不上（看落地机服务/防火墙）\n' "$tc_r" "$tc_p"
				fi
			elif ! command -v ping >/dev/null 2>&1; then
				echo "  (系统没有 ping 也没有 nc，跳过连通性测试)"
			fi
		done <<EOF
$(conf_read)
EOF
	else
		echo "  (没有配置)"
	fi
	[ "$bad" = "0" ] || die "存在不完整的规则，执行 portfwd.sh apply 修复"
	return 0
}

cmd_open_port() {
	[ $# -gt 0 ] || die "用法: portfwd.sh open-port <端口> [端口...]"
	need_root
	ensure_iptables
	probe_comment
	for cp_p in "$@"; do
		is_port "$cp_p" || die "端口不合法: $cp_p"
	done
	open_port_now "$@"
	persist
	return 0
}

cmd_uninstall() {
	need_root
	ensure_iptables
	probe_comment
	echo "将删除：所有 portfwd 规则、$CONF、开机自启配置、/usr/local/sbin/portfwd"
	confirm "确定卸载？" || die "已取消"
	del_tagged nat:PREROUTING nat:POSTROUTING filter:INPUT filter:FORWARD
	if [ -f /etc/systemd/system/portfwd.service ]; then
		systemctl disable portfwd.service >/dev/null 2>&1
		rm -f /etc/systemd/system/portfwd.service
		systemctl daemon-reload >/dev/null 2>&1
		ok "已移除 systemd 服务"
	fi
	rm -f "$CONF" "$OPEN_FILE" /etc/local.d/portfwd.start /usr/local/sbin/portfwd /etc/sysctl.d/99-portfwd.conf
	if command -v iptables-save >/dev/null 2>&1; then
		mkdir -p /etc/iptables
		iptables-save >/etc/iptables/rules-save 2>/dev/null
	fi
	ok "已卸载（ip_forward 保持开启，如需关闭: sysctl -w net.ipv4.ip_forward=0）"
	return 0
}

usage() {
	cat <<'EOF'
portfwd.sh —— 端口转发一键配置（转发机 → 落地机）

不带参数 = 向导模式（先测线路质量，再配置）：
    portfwd.sh

带参数（适合脚本/批量）：
    portfwd.sh add -l 10888 -r 1.2.3.4 -p 443 -y
    portfwd.sh 10888 1.2.3.4 443

其它命令：
    portfwd.sh probe 1.2.3.4     只测线路质量（ping/丢包），不写任何规则
    portfwd.sh list                     查看映射与规则
    portfwd.sh test                     自检（规则 + 落地机 ping/TCP）
    portfwd.sh rm 10888                 删除一条映射
    portfwd.sh apply                    按 /etc/portfwd.conf 重放（开机用）
    portfwd.sh open-port 10888          本机防火墙放行该端口
    portfwd.sh uninstall                彻底卸载
    portfwd.sh help                     本帮助

参数：
    -l, --local-port    转发机本地 NAT 端口
    -r, --remote-ip     落地机 IP
    -p, --remote-port   落地机端口
    -y, --yes           不再确认
    -q, --quiet         安静模式
    --no-probe          跳过线路质量检测
    --probe-count N     ping 次数（默认 10）
EOF
}

# -----------------------------------------------------------------------------
# 入口
# -----------------------------------------------------------------------------
main() {
	case "${1:-wizard}" in
	help | -h | --help)
		usage
		return 0
		;;
	-v | --version)
		echo "portfwd.sh $VERSION"
		return 0
		;;
	esac

	# 全局开关放最前面，任何子命令都能用：portfwd.sh -y 10888 1.2.3.4 443
	while [ $# -gt 0 ]; do
		case "$1" in
		-y | --yes) ASSUME_YES=1; shift ;;
		-q | --quiet) QUIET=1; shift ;;
		--no-probe) NO_PROBE=1; shift ;;
		--probe-count)
			[ $# -ge 2 ] || die "--probe-count 缺少参数"
			P_COUNT=$2
			is_port "$P_COUNT" && [ "$P_COUNT" -le 100 ] ||
				die "--probe-count 需要 1-100 的数字"
			shift 2
			;;
		*) break ;;
		esac
	done

	escalate_if_needed "$@"

	_cmd=${1:-wizard}
	case "$_cmd" in
	# 不要在这里 shift：$# 为 0 时 shift 是 POSIX 特殊内建命令的失败，
	# dash（Ubuntu/Debian 的 /bin/sh）会因此直接退出整个脚本，表现为「无任何输出」
	'' | wizard) wizard ;;
	help | -h | --help) usage ;;
	-v | --version) echo "portfwd.sh $VERSION" ;;
	add) shift; cmd_add "$@" ;;
	probe | ping) shift; cmd_probe "$@" ;;
	rm | del | delete) shift; cmd_rm "$@" ;;
	list | ls | show) cmd_list ;;
	apply | sync) shift; cmd_apply "$@" ;;
	boot) cmd_boot ;;
	test | check) cmd_test ;;
	open-port | open) shift; cmd_open_port "$@" ;;
	uninstall | remove) cmd_uninstall ;;
	-[lrp]* | --*) cmd_add "$@" ;;
	*[!0-9]*) die "未知命令: $_cmd（执行 portfwd.sh help 查看用法）" ;;
	*) cmd_add_pos "$@" ;;
	esac
}

main "$@"
