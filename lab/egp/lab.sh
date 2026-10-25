#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# EGP 双路由器实验（Podman）。两台隔离容器，各自跑 zebra + egpd，
# 在实验网段 198.18.123.0/24 上交换 EGP（IP 协议号 8）。
#
# 依赖：podman；S4 的安装前缀（zebra/egpd/vtysh/libfrr 同一次构建）；
#      由同目录 Containerfile 构建的镜像。
#
# 只操作本实验创建的资源（容器 ${LAB_NAME_PREFIX}1/2、网络 $LAB_NET），
# 不触碰宿主机其它容器、网络或系统 FRR。
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 参数：先取 lab.env.example 的默认值，再用 lab.env 覆盖（lab.env 可以只写要改的项）
ENV_DEFAULTS="$HERE/lab.env.example"
[ -f "$ENV_DEFAULTS" ] || { echo "缺少 $ENV_DEFAULTS" >&2; exit 1; }
# shellcheck disable=SC1090
. "$ENV_DEFAULTS"
if [ -f "$HERE/lab.env" ]; then
	ENV_FILE="$HERE/lab.env"
	# shellcheck disable=SC1090
	. "$ENV_FILE"
else
	ENV_FILE="$ENV_DEFAULTS"
fi

R1="${LAB_NAME_PREFIX}1"
R2="${LAB_NAME_PREFIX}2"
LOG_DIR="$LAB_RUNDIR/logs"

log()  { printf '[%s] %-5s %s\n' "$(date -u +%H:%M:%SZ)" lab "$*"; }
die()  { printf '[%s] %-5s FAIL %s\n' "$(date -u +%H:%M:%SZ)" lab "$*" >&2; exit 1; }

usage() {
	cat <<EOF
用法: $0 <命令>

  build            用 lab/egp/${LAB_CONTAINERFILE} 构建实验镜像 $LAB_IMAGE
  up               预检 + 创建网络/容器 + 启动 zebra/egpd（等待邻居 Up）
  status           显示两个路由器的 egpd 邻居、zebra 的 EGP 路由、内核路由
  vty N            进入路由器 N（1|2）的 vtysh
  exec N -- CMD..  在路由器 N 的容器里执行命令
  test             跑集成测试（test_lab.py，12 项）
  down             删除本实验的容器与网络（只删本实验的）
  env              打印当前生效的参数（不含任何凭据）

参数文件: $ENV_FILE
EOF
}

# ---------- 安全：只允许操作本实验的资源 ----------
ipv4_ok() {
	[ "$(printf '%s' "$1" | grep -cE '^([0-9]{1,3}\.){3}[0-9]{1,3}$')" = 1 ] || return 1
	local o
	for o in $(printf '%s' "$1" | tr '.' ' '); do
		[ "$((10#$o))" -le 255 ] || return 1
	done
	return 0
}

abs_path_ok() {
	case "$1" in
		/) return 1 ;;
		/*) ;;
		*) return 1 ;;
	esac
	return 0
}

# 参数白名单校验：拒绝空值、非法字符、危险路径（每个命令入口都会调）
check_params() {
	[ -n "${LAB_IMAGE:-}" ] && [[ "$LAB_IMAGE" =~ ^[A-Za-z0-9._/:@-]+$ ]] \
		|| die "LAB_IMAGE 非法: '${LAB_IMAGE:-}'"
	[[ "${LAB_NAME_PREFIX:-}" =~ ^[a-z0-9][a-z0-9-]*$ ]] \
		|| die "LAB_NAME_PREFIX 只允许 [a-z0-9-] 且不能以 - 开头: '${LAB_NAME_PREFIX:-}'"
	[[ "${LAB_NET:-}" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] \
		|| die "LAB_NET 非法（这会作为 podman 网络名）: '${LAB_NET:-}'"
	[[ "${LAB_SUBNET:-}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] \
		|| die "LAB_SUBNET 不是 CIDR: '${LAB_SUBNET:-}'"
	ipv4_ok "${LAB_IP1:-}" || die "LAB_IP1 不是合法 IPv4: '${LAB_IP1:-}'"
	ipv4_ok "${LAB_IP2:-}" || die "LAB_IP2 不是合法 IPv4: '${LAB_IP2:-}'"
	[ "$LAB_IP1" != "$LAB_IP2" ] || die "LAB_IP1 与 LAB_IP2 不能相同: $LAB_IP1"
	abs_path_ok "${LAB_PREFIX:-}" || die "LAB_PREFIX 必须是绝对路径且不是 /: '${LAB_PREFIX:-}'"
	abs_path_ok "${LAB_MOUNT:-}"  || die "LAB_MOUNT 必须是绝对路径且不是 /: '${LAB_MOUNT:-}'"
	abs_path_ok "${LAB_RUNDIR:-}" || die "LAB_RUNDIR 必须是绝对路径且不是 /: '${LAB_RUNDIR:-}'"
	ipv4_ok "${LAB_NET1:-}" || die "LAB_NET1 不是合法 IPv4: '${LAB_NET1:-}'"
	ipv4_ok "${LAB_NET2:-}" || die "LAB_NET2 不是合法 IPv4: '${LAB_NET2:-}'"
	local a
	for a in "${LAB_AS1:-}" "${LAB_AS2:-}"; do
		[[ "$a" =~ ^[0-9]+$ ]] && [ "$a" -ge 1 ] && [ "$a" -le 65535 ] \
			|| die "AS 号必须是 1..65535: '$a'"
	done
	[[ "${LAB_UDP_PORT:-}" =~ ^[0-9]+$ ]] && [ "$LAB_UDP_PORT" -ge 1 ] && [ "$LAB_UDP_PORT" -le 65535 ] \
		|| die "LAB_UDP_PORT 必须是 1..65535: '${LAB_UDP_PORT:-}'"
	[[ "${LAB_TIMERS:-}" =~ ^[0-9]+\ [0-9]+$ ]] || die "LAB_TIMERS 需形如 '2 6': '${LAB_TIMERS:-}'"
	return 0
}

assert_our_container() {
	case "$1" in
		"$R1"|"$R2") ;;
		*) die "拒绝操作非本实验容器: $1" ;;
	esac
}
assert_our_network() {
	[ "$1" = "$LAB_NET" ] || die "拒绝操作非本实验网络: $1"
}

# ---------- 预检 ----------
need_podman() {
	command -v podman >/dev/null 2>&1 || die "找不到 podman"
	podman info >/dev/null 2>&1 || die "podman 不可用（podman info 失败）"
}

check_prefix() {
	local f
	for f in sbin/egpd sbin/zebra bin/vtysh; do
		[ -x "$LAB_PREFIX/$f" ] || die "缺少 $LAB_PREFIX/$f（先执行 S4 的 scripts/build.sh）"
	done
	find "$LAB_PREFIX" -maxdepth 3 -name 'libfrr.so.0' -print -quit 2>/dev/null | grep -q . \
		|| die "缺少 $LAB_PREFIX 下的 libfrr.so.0"
	# zebra 启动时要 mkdir $(localstatedir)/lib/frr 与 $(runstatedir)/frr；
	# 前缀是只读挂载，所以这两个目录必须是"挂载点"：先在宿主侧建空目录，
	# 容器里再用 tmpfs 盖住（见 podman run 的 --tmpfs）。
	mkdir -p "$LAB_PREFIX/var" "$LAB_PREFIX/run"
	log "安装前缀: $LAB_PREFIX（egpd/zebra/vtysh/libfrr 均存在，var/run 挂载点已就绪）"
}

check_image() {
	podman image exists "$LAB_IMAGE" || die "镜像 $LAB_IMAGE 不存在，先执行: $0 build"
	log "实验镜像: $LAB_IMAGE"
}

check_conflicts() {
	podman container exists "$R1" && die "容器 $R1 已存在；先执行 $0 down，或改 LAB_NAME_PREFIX"
	podman container exists "$R2" && die "容器 $R2 已存在；先执行 $0 down，或改 LAB_NAME_PREFIX"
	podman network exists "$LAB_NET" && die "网络 $LAB_NET 已存在；先执行 $0 down，或改 LAB_NET"
	log "资源名无冲突: $R1 / $R2 / $LAB_NET"
}

# 一次性探针：libfrr 必须来自挂载的前缀；容器必须具备 NET_ADMIN / NET_RAW
probe_container() {
	local out
	out="$(podman run --rm \
		--cap-add NET_ADMIN --cap-add NET_RAW \
		--security-opt label=disable \
		-v "$LAB_PREFIX:$LAB_MOUNT:ro" \
		"$LAB_IMAGE" sh -ec '
			# libfrr 必须解析到挂载前缀里的 lib（RUNPATH=$ORIGIN/../lib 时 ldd 会显示
			# /build/prefix/sbin/../lib，所以这里按"落在 /build/prefix 之下且文件名正确"判断）
			lib=$(ldd /build/prefix/sbin/egpd 2>/dev/null | grep -F 'libfrr.so.0 =>' | awk '{print $3}')
			case "$lib" in
				/build/prefix/*lib/libfrr.so.0|/build/prefix/*/lib/libfrr.so.0) : ;;
				*) echo LIBFRR_NOT_FROM_PREFIX; exit 3 ;;
			esac
			ip link add hrtest0 type dummy 2>/dev/null || { echo NO_NET_ADMIN; exit 4; }
			ip link del hrtest0
			python3 -c "import socket; s=socket.socket(socket.AF_INET, socket.SOCK_RAW, 8); s.close()" 2>/dev/null \
				|| { echo NO_NET_RAW; exit 5; }
			echo PROBE_OK
		' 2>&1)" || die "预检探针失败: $out"
	case "$out" in
		*PROBE_OK*) log "探针通过: libfrr 来自挂载前缀；具备 NET_ADMIN + NET_RAW" ;;
		*) die "预检探针异常输出: $out" ;;
	esac
}

# ---------- 容器内动作 ----------
vty() {
	local n="$1"; shift
	podman exec "$n" /build/prefix/bin/vtysh --vty_socket /tmp/run "$@"
}

start_daemon() {
	local name="$1" d="$2"
	# 启动输出（含 privs/路径错误）留在容器内 /tmp/egp/<daemon>.start.log
	podman exec "$name" sh -c "/build/prefix/sbin/$d -d -u root -g root \
		-f /tmp/egp/$d.conf -i /tmp/run/$d.pid -z /tmp/run/zserv.api --vty_socket /tmp/run \
		>>/tmp/egp/$d.start.log 2>&1" >/dev/null 2>&1 || true
}

setup_router() {
	local idx="$1" name="$2" ip="$3" as="$4" stub="$5" host="$6" peer_ip="$7" peer_as="$8"
	log "[$name] stub0=$host 宣告 $stub 邻居 $peer_ip AS $peer_as 本地 AS $as"
	podman exec "$name" sh -ec "
		mkdir -p /tmp/run /tmp/egp
		ip link show stub0 >/dev/null 2>&1 || ip link add stub0 type dummy
		ip link set stub0 up
		ip addr replace $host dev stub0
		printf 'hostname egp-r$idx\nlog file /tmp/egp/zebra.log\n' > /tmp/egp/zebra.conf
		printf 'hostname egp-r$idx\nlog file /tmp/egp/egpd.log\negp local-as $as\negp timers $LAB_TIMERS\negp network $stub\negp neighbor $peer_ip local-address $ip remote-as $peer_as\n' > /tmp/egp/egpd.conf
	" >/dev/null
	start_daemon "$name" zebra
	sleep 2
	start_daemon "$name" egpd
}

neighbors_up() {
	vty "$R1" -d zebra -c 'show version' >/dev/null 2>&1 &&
	vty "$R2" -d zebra -c 'show version' >/dev/null 2>&1 &&
	vty "$R1" -d egpd -c 'show ip egp neighbors' 2>/dev/null | grep -q "Up" &&
	vty "$R2" -d egpd -c 'show ip egp neighbors' 2>/dev/null | grep -q "Up"
}

wait_neighbors() {
	local i
	for i in $(seq 1 40); do
		if neighbors_up; then
			log "两端 EGP 邻居均已 Up（约 ${i}s）"
			return 0
		fi
		sleep 1
	done
	return 1
}

# ---------- 命令 ----------
cmd_build() {
	need_podman
	[ -f "$HERE/$LAB_CONTAINERFILE" ] || die "找不到 $HERE/$LAB_CONTAINERFILE"
	log "构建镜像 $LAB_IMAGE（基础镜像 $LAB_BASE_IMAGE）"
	podman build --build-arg BASE_IMAGE="$LAB_BASE_IMAGE" \
		-t "$LAB_IMAGE" -f "$HERE/$LAB_CONTAINERFILE" "$HERE" || die "镜像构建失败"
	log "镜像构建完成: $LAB_IMAGE"
}

cmd_up() {
	need_podman
	check_image
	check_prefix
	check_conflicts
	probe_container

	# 从这里开始会创建资源：中途失败要提示怎么清理，避免留下半成品
	trap 'printf "[%s] lab   WARN  up 未完成；执行 %s down 清理已创建的网络/容器\n" "$(date -u +%H:%M:%SZ)" "$0" >&2' ERR

	mkdir -p "$LOG_DIR"
	log "创建实验网络 $LAB_NET（$LAB_SUBNET）"
	podman network create "$LAB_NET" --subnet "$LAB_SUBNET" >/dev/null

	local idx name ip
	for idx in 1 2; do
		name="${LAB_NAME_PREFIX}${idx}"
		if [ "$idx" = 1 ]; then ip="$LAB_IP1"; else ip="$LAB_IP2"; fi
		log "创建容器 $name（$ip）"
		# --init：容器 PID 1 用 podman 的 init 回收子进程，否则被杀掉的 daemon
		# 会以僵尸状态长期留在进程表，使"进程是否在运行"的判定失真。
		podman run -d --init --name "$name" \
			--network "$LAB_NET" --ip "$ip" \
			--cap-add NET_ADMIN --cap-add NET_RAW --cap-add SYS_ADMIN \
			--security-opt label=disable \
			-v "$LAB_PREFIX:$LAB_MOUNT:ro" \
			--tmpfs "$LAB_MOUNT/var:rw,mode=1777" \
			--tmpfs "$LAB_MOUNT/run:rw,mode=1777" \
			"$LAB_IMAGE" >/dev/null
	done

	setup_router 1 "$R1" "$LAB_IP1" "$LAB_AS1" "$LAB_NET1" "$LAB_HOST1" "$LAB_IP2" "$LAB_AS2"
	setup_router 2 "$R2" "$LAB_IP2" "$LAB_AS2" "$LAB_NET2" "$LAB_HOST2" "$LAB_IP1" "$LAB_AS1"

	if wait_neighbors; then
		trap - ERR
		log "实验就绪：$0 status / $0 test / $0 vty 1"
	else
		cmd_status || true
		for n in "$R1" "$R2"; do
			for d in zebra egpd; do
				echo "--- $n /tmp/egp/$d.start.log"
				podman exec "$n" sh -c "cat /tmp/egp/$d.start.log 2>/dev/null | tail -10" || true
			done
		done
		die "40 秒内未就绪（邻居未 Up 或 zebra vty 不可用）"
	fi
}

cmd_status() {
	local n
	for n in "$R1" "$R2"; do
		echo "=============== $n"
		echo "--- 进程"
		podman exec "$n" sh -c 'ps -eo pid,comm | grep -E "zebra|egpd" | grep -v grep' 2>/dev/null || echo "(无)"
		echo "--- egpd 邻居"
		vty "$n" -d egpd -c 'show ip egp neighbors' 2>/dev/null || echo "(查询失败)"
		echo "--- zebra 的 EGP 路由（文本视角，'G' 前缀即 EGP）"
		vty "$n" -d zebra -c 'show ip route' 2>/dev/null | grep -E "^G" || echo "(无 EGP 路由)"
		echo "--- 内核路由（stub / 实验网段）"
		podman exec "$n" ip -4 route 2>/dev/null | grep -E "10\.|172\.16|198\.18" || echo "(无)"
	done
}

cmd_vty() {
	local n="${1:?用法: $0 vty 1|2}"
	assert_our_container "$n"
	exec podman exec -it "$n" /build/prefix/bin/vtysh --vty_socket /tmp/run
}

cmd_exec() {
	local n="${1:?用法: $0 exec 1|2 -- CMD...}"
	shift
	[ "${1:-}" = "--" ] && shift
	assert_our_container "$n"
	podman exec "$n" "$@"
}

cmd_test() {
	need_podman
	podman container exists "$R1" || die "实验未启动（$R1 不存在）；先执行 $0 up"
	podman container exists "$R2" || die "实验未启动（$R2 不存在）；先执行 $0 up"
	mkdir -p "$LOG_DIR"
	# 把参数显式导出给 test_lab.py（唯一来源仍是 lab.env / lab.env.example）
	export LAB_MOUNT LAB_PREFIX LAB_NAME_PREFIX LAB_R1="$R1" LAB_R2="$R2" \
		LAB_IP1 LAB_IP2 LAB_AS1 LAB_AS2 LAB_TIMERS LAB_NET1 LAB_HOST1 LAB_NET2 LAB_HOST2 \
		LAB_UDP_PORT LAB_RUNDIR LAB_ENV_FILE="$ENV_FILE"
	python3 "$HERE/test_lab.py"
}

cmd_down() {
	need_podman
	local n
	for n in "$R1" "$R2"; do
		assert_our_container "$n"
		if podman container exists "$n"; then
			log "删除容器 $n"
			podman rm -f "$n" >/dev/null
		else
			log "容器 $n 不存在，跳过"
		fi
	done
	assert_our_network "$LAB_NET"
	if podman network exists "$LAB_NET"; then
		log "删除网络 $LAB_NET"
		podman network rm "$LAB_NET" >/dev/null
	else
		log "网络 $LAB_NET 不存在，跳过"
	fi
	log "清理完成（本实验资源已全部移除）"
}

cmd_env() {
	echo "参数文件: $ENV_FILE"
	echo "LAB_IMAGE=$LAB_IMAGE  BASE=$LAB_BASE_IMAGE"
	echo "LAB_PREFIX=$LAB_PREFIX  LAB_MOUNT=$LAB_MOUNT"
	echo "LAB_NET=$LAB_NET  LAB_SUBNET=$LAB_SUBNET"
	echo "容器: $R1=$LAB_IP1  $R2=$LAB_IP2"
	echo "AS: $LAB_AS1 / $LAB_AS2  timers=${LAB_TIMERS}"
	echo "宣告: $LAB_NET1($LAB_HOST1)  $LAB_NET2($LAB_HOST2)"
	echo "LAB_RUNDIR=$LAB_RUNDIR"
	# 软校验：env 只报告，不因为参数非法而拒绝打印（方便排查）
	if ( check_params ) >/dev/null 2>&1; then
		echo "参数校验: OK"
	else
		echo "参数校验: 有非法项（其它命令会拒绝执行；单独跑一次 check 看原因）"
	fi
}

cmd="${1:-}"
[ $# -gt 0 ] && shift
case "$cmd" in
	build)  check_params; cmd_build ;;
	up)     check_params; cmd_up ;;
	status) check_params; cmd_status ;;
	vty)    check_params; cmd_vty "$@" ;;
	exec)   check_params; cmd_exec "$@" ;;
	test)   check_params; cmd_test ;;
	down)   check_params; cmd_down ;;
	env)    cmd_env ;;
	''|-h|--help|help) usage ;;
	*) usage; die "未知命令: $cmd" ;;
esac
