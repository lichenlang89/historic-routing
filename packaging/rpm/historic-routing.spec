# SPDX-License-Identifier: GPL-2.0-or-later
#
# historic-routing RPM —— 开发验证构建（未发布）
#
# 设计要点（详见 packaging/rpm/README.md）：
#   1. 源码构建在 %build 里真跑：SOURCES 里的 tarball 是 git archive 出来的
#      本仓库快照，%build 调用 scripts/build.sh 从固定 FRR 基线完整构建，
#      **不是**把某个已有构建目录压包。
#   2. 安装到 /opt/historic-routing/<FRR短提交>/，与系统 FRR（/usr、/etc/frr、
#      /usr/lib64/frr）完全隔离。
#   3. 二进制带 RUNPATH=<prefix>/lib，运行期不会误加载系统 libfrr。
#   4. runtime 与 egp 用 hr_abi（源码提交 + FRR 提交）做严格绑定，
#      egp 还要求 runtime 的 version-release 完全相等。
#   5. 服务只安装、不 enable、不 start。
#   6. 卸载脚本只操作本项目自己的 unit，不删任何外部资源。

%{!?hr_version:%global hr_version 0.1.1}
%{!?hr_release:%global hr_release 0.1.dev2262b0e}
%{!?hr_git:%global hr_git 2262b0e5e8f75896807f6470d6c967bd79c873ea}
%{!?hr_git_short:%global hr_git_short 2262b0e}
%{!?hr_frr:%global hr_frr 27f287be9210d4024a140486b7b8ddd5eb41fe04}
%{!?hr_frr_short:%global hr_frr_short 27f287be9}

%global hr_prefix /opt/historic-routing/%{hr_frr_short}
%global hr_abi %{hr_git_short}-%{hr_frr_short}

%global debug_package %{nil}
# 私有共享库不参与系统的 soname 命名空间：
#   * 不自动 Provide libfrr.so.0()(64bit) —— 否则会和系统 frr 包"同名提供"，
#     让 rpm/dnf 认为两者可互换（实测 rpm -q --whatprovides 会同时列出两包）；
#   * 不自动 Require libfrr.so.0()(64bit) —— 它由本包自带，靠 RUNPATH=$ORIGIN/../lib 解析，
#     不应该被系统 frr 满足（那会变成"依赖系统 FRR 才能装"）。
%global __provides_exclude_from ^%{hr_prefix}/lib/.*\.so.*$
%global __requires_exclude ^libfrr\.so\.0.*$
# rpath 说明：打包阶段用 patchelf 把 RUNPATH 改成 $ORIGIN/../lib（见下文），
# 因此不产生 /opt 绝对 rpath，rpm 的 brp check-rpaths 不需要任何豁免就通过。

Name:           historic-routing-runtime
Version:        %{hr_version}
Release:        %{hr_release}%{?dist}
Summary:        FRRouting framework for historic routing protocols (development build)
License:        GPL-2.0-or-later
URL:            https://github.com/lichenlang89/historic-routing
Source0:        historic-routing-%{hr_version}.tar.gz
Source1:        historic-routing-zebra.service
Source2:        historic-routing-egpd.service
BuildArch:      x86_64

# 只用同一棵 FRR 树构建：runtime 与 egp 共用这个 ABI 标识
Provides:       historic-routing-abi = %{hr_abi}
Provides:       historic-routing-abi-%{hr_frr_short} = %{hr_abi}

BuildRequires:  gcc gcc-c++ make autoconf automake libtool bison flex patch tar gzip git
BuildRequires:  python3-devel python3-pytest python3-pytest-xdist
BuildRequires:  json-c-devel libyang-devel libcap-devel readline-devel pcre2-devel
BuildRequires:  c-ares-devel elfutils-libelf-devel systemd-devel pkgconf-pkg-config
BuildRequires:  patchelf
Requires:       /bin/sh

%description
historic-routing 是一个独立项目：以 FRRouting 为底层框架，复活已经退出主流
使用的历史路由协议（EGP、GGP、HELLO…）。本项目不是 FRRouting 官方项目。

本包是**开发验证构建**（release 字段带 development 与源码提交号），不是正式发布版本。
它提供共享框架：共享运行时库、zebra、vtysh 与配置骨架，安装到
%{hr_prefix}，与系统 FRR（/usr、/etc/frr、/usr/lib64/frr）互不覆盖。

注意：本包的 zebra 与系统 frr.service 中的 zebra 属于两个互不兼容的控制面，
**不要同时运行**；详见 packaging/rpm/README.md。

%package -n historic-routing-egp
Summary:        Experimental EGP (RFC 904) daemon for historic-routing
Requires:       historic-routing-runtime%{?_isa} = %{version}-%{release}
Requires:       historic-routing-abi = %{hr_abi}

%description -n historic-routing-egp
historic-routing 的 EGP（RFC 904）守护进程 egpd。这是实验性的 stub gateway 实现，
不是 RFC 904 意义上的 core gateway，也不建议用于生产网络。
本包是开发验证构建，必须与同一次构建产出的 historic-routing-runtime 严格配对
（ABI 标识 %{hr_abi}）。

%prep
# tarball 顶层目录是 historic-routing-<version>（不是 Name-version）
%setup -q -n historic-routing-%{hr_version}

%build
%{?set_build_flags}
export RPM_ARCH=%{_arch}
test -x scripts/build.sh || { echo "源码不完整：缺 scripts/build.sh" >&2; exit 1; }
# 可选：源码传输来源覆盖（离线/镜像构建）。内容仍由固定提交 + 补丁 SHA256 校验。
if [ -n "%{?hr_frr_repo}" ]; then
	export HR_FRR_REPO="%{hr_frr_repo}"
	echo "源码来源覆盖: $HR_FRR_REPO（提交仍须等于 BASELINE）"
fi
# 固定基线必须与打包参数一致，否则拒绝构建（防止把别的树打进包）
baseline_commit="$(sed -n 's/^FRR_COMMIT=//p' patches/frr/BASELINE | head -1)"
test "$baseline_commit" = "%{hr_frr}" || {
	echo "BASELINE=$baseline_commit 与打包参数 %{hr_frr} 不一致" >&2; exit 1; }
# 编译参数：去掉 rpmbuild 注入的 LTO（原因见下）
# 同时去掉 rpmbuild 注入的 LTO：FRR 的 libfrr 在 glibc 2.39+ + FORTIFY_SOURCE=3 下用
# -flto=auto 会报 "inlining failed in call to 'always_inline' 'inet_ntop'"
# （LTO 与 fortify 的已知冲突）。其余 optflags（加固、-march 等）保留；
# LTO 不是本项目的发布要求，也不影响功能验证。
_strip_lto() {
	printf '%s' "$1" | sed -e 's/ -flto=auto//g' -e 's/ -ffat-lto-objects//g' \
		-e 's/ -flto=[a-z0-9]*//g' -e 's/ -flto//g' -e 's/^ *//' -e 's/ *$//'
}
CFLAGS="$(_strip_lto "${CFLAGS:-%{optflags}}")"
CXXFLAGS="$(_strip_lto "${CXXFLAGS:-$CFLAGS}")"
LDFLAGS="$(_strip_lto "${LDFLAGS:-}")"
export CFLAGS CXXFLAGS LDFLAGS
# --prefix 用**最终安装路径**（libtool 会按它写 RUNPATH，运行期才能找到本前缀的 libfrr）；
# --destdir 把文件暂存到构建目录，构建过程不写真实 /opt。
./scripts/build.sh \
	--jobs %(nproc) \
	--build-root %{_builddir}/hr-build \
	--prefix %{hr_prefix} \
	--destdir %{_builddir}/hr-build/dest \
	--protocols egp

%install
rm -rf %{buildroot}
install -d %{buildroot}%{hr_prefix}
test -f %{_builddir}/hr-build/fingerprint.txt || {
	echo "构建根里没有 fingerprint.txt，拒绝打包（必须来自 scripts/build.sh）" >&2; exit 1; }

# DEST（暂存安装根）里已经是 make install DESTDIR=dest 的完整树
DEST=%{_builddir}/hr-build/dest%{hr_prefix}

# 只装 runtime 需要的东西：共享库 + zebra + vtysh + 配置骨架
install -d %{buildroot}%{hr_prefix}/{bin,sbin,lib,etc/frr,run/frr,var/lib/frr}
cp -a $DEST/lib/libfrr.so.0* %{buildroot}%{hr_prefix}/lib/
# 说明：lib/frr/modules/*.so（bgpd_bmp / dplane_fpm_nl / zebra_cumulus_mlag）**不打包**。
# 它们与本项目的 zebra/egpd 无关，而且需要额外的 libfrrcares.so.0 —— 一起打进来
# 只会把"系统 frr 的 soname"拖进依赖里（实测会把 Requires: libfrrcares.so.0()(64bit)
# 带进本包）。不装这些模块，依赖面最小。
install -m 0755 $DEST/sbin/zebra %{buildroot}%{hr_prefix}/sbin/zebra
install -m 0755 $DEST/bin/vtysh %{buildroot}%{hr_prefix}/bin/vtysh
# RUNPATH 改成 $ORIGIN 相对路径：
#   * 运行期只会在**本前缀**的 lib/ 里找 libfrr（sbin/../lib、bin/../lib），
#     不会落到系统的 /usr/lib64/frr/；
#   * 前缀整体搬走（例如实验容器挂到 /build/prefix）也能用；
#   * 不引入 /opt 这种"非标准绝对 rpath"，rpm check-rpaths 与 rpmlint 都干净。
patchelf --set-rpath '$ORIGIN/../lib' %{buildroot}%{hr_prefix}/sbin/zebra %{buildroot}%{hr_prefix}/bin/vtysh

# 配置骨架：daemons 来自本次构建（egpd=no），frr.conf 给最小可跑示例
install -m 0644 $DEST/etc/frr/daemons %{buildroot}%{hr_prefix}/etc/frr/daemons 2>/dev/null || \
	printf 'zebra=yes\negpd=no\n' > %{buildroot}%{hr_prefix}/etc/frr/daemons
cat > %{buildroot}%{hr_prefix}/etc/frr/frr.conf <<'CONF'
! historic-routing 示例配置（%{hr_prefix}/etc/frr/frr.conf）
! 这是开发验证构建的骨架，按需修改；升级时不会被覆盖（%config(noreplace)）
hostname historic-routing
! EGP 示例（egp 包安装后可用）：
! egp local-as 65001
! egp timers 30 120
! egp network 10.0.0.0
CONF

# vtysh 自己的配置（FRR 会读；空文件即可，避免 "No such file" 噪声）
printf '! historic-routing vtysh.conf\n' > %{buildroot}%{hr_prefix}/etc/frr/vtysh.conf
chmod 0644 %{buildroot}%{hr_prefix}/etc/frr/vtysh.conf

# 构建溯源信息（版本 / 源码提交 / FRR 提交 / 指纹）
{
	echo "# historic-routing RPM build info"
	echo "package_version=%{version}-%{release}"
	echo "source_commit=%{hr_git}"
	echo "frr_commit=%{hr_frr}"
	echo "abi=%{hr_abi}"
	echo "prefix=%{hr_prefix}"
	echo "build_host=$(uname -n) $(uname -m)"
	echo "built_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	echo "---- fingerprint.txt ----"
	cat %{_builddir}/hr-build/fingerprint.txt
} > %{buildroot}%{hr_prefix}/RPM-BUILD-INFO.txt
chmod 0644 %{buildroot}%{hr_prefix}/RPM-BUILD-INFO.txt

install -d %{buildroot}%{_unitdir}
sed 's|@PREFIX@|%{hr_prefix}|g' %{SOURCE1} > %{buildroot}%{_unitdir}/historic-routing-zebra.service
chmod 0644 %{buildroot}%{_unitdir}/historic-routing-zebra.service

# ---- egp 子包的文件 ----
install -d %{buildroot}%{hr_prefix}/sbin
install -m 0755 $DEST/sbin/egpd %{buildroot}%{hr_prefix}/sbin/egpd
patchelf --set-rpath '$ORIGIN/../lib' %{buildroot}%{hr_prefix}/sbin/egpd

# 显式 strip：rpmbuild 的 brp-strip 只去 .debug_*，仍留 .symtab（rpmlint 视为未 strip）。
# 这里对**本包自己的**可执行文件做 --strip-unneeded（不动系统任何文件）。
strip --strip-unneeded %{buildroot}%{hr_prefix}/sbin/zebra \
	%{buildroot}%{hr_prefix}/bin/vtysh %{buildroot}%{hr_prefix}/sbin/egpd 2>/dev/null || :
for l in %{buildroot}%{hr_prefix}/lib/libfrr.so.*; do
	if [ -f "$l" ] && [ ! -L "$l" ]; then strip --strip-unneeded "$l" 2>/dev/null || :; fi
done
for so in %{buildroot}%{hr_prefix}/lib/frr/modules/*.so; do
	if [ -e "$so" ]; then strip --strip-unneeded "$so" 2>/dev/null || :; fi
done
cat > %{buildroot}%{hr_prefix}/etc/frr/egpd.conf <<'CONF'
! egpd 独立运行时的最小配置（由 egp 包提供）
! 用 systemd 的 historic-routing-egpd.service 时读这个文件；
! 与 zebra 共用 frr.conf 的集成模式请改用 vtysh 配置。
hostname egp-r1
log file %{hr_prefix}/run/egpd.log
egp local-as 65001
egp timers 30 120
CONF
install -m 0644 %{SOURCE2} %{buildroot}%{_unitdir}/historic-routing-egpd.service
sed -i 's|@PREFIX@|%{hr_prefix}|g' %{buildroot}%{_unitdir}/historic-routing-egpd.service

%post
# 只刷新 unit 缓存：不 enable、不 start
systemctl daemon-reload >/dev/null 2>&1 || :

%preun
if [ $1 -eq 0 ]; then
	# 只在卸载时停自己的 unit；不碰系统 frr.service
	systemctl stop historic-routing-egpd.service >/dev/null 2>&1 || :
fi

%postun
systemctl daemon-reload >/dev/null 2>&1 || :

%files
%license LICENSE
%doc README.md CHANGELOG.md docs/ARCHITECTURE.md docs/FIDELITY.md docs/PACKAGING.md
%dir %{hr_prefix}
%dir %{hr_prefix}/bin
%dir %{hr_prefix}/sbin
%dir %{hr_prefix}/lib
%dir %{hr_prefix}/etc
%dir %{hr_prefix}/etc/frr
%dir %{hr_prefix}/run
%dir %{hr_prefix}/run/frr
%dir %{hr_prefix}/var
%dir %{hr_prefix}/var/lib
%dir %{hr_prefix}/var/lib/frr
%{hr_prefix}/lib/libfrr.so.0*
%{hr_prefix}/sbin/zebra
%{hr_prefix}/bin/vtysh
%{hr_prefix}/RPM-BUILD-INFO.txt
%config(noreplace) %{hr_prefix}/etc/frr/daemons
%config(noreplace) %{hr_prefix}/etc/frr/frr.conf
%config(noreplace) %{hr_prefix}/etc/frr/vtysh.conf
%{_unitdir}/historic-routing-zebra.service

%files -n historic-routing-egp
%doc protocols/egp/README.md
%dir %{hr_prefix}
%dir %{hr_prefix}/sbin
%dir %{hr_prefix}/etc
%dir %{hr_prefix}/etc/frr
%{hr_prefix}/sbin/egpd
%config(noreplace) %{hr_prefix}/etc/frr/egpd.conf
%{_unitdir}/historic-routing-egpd.service

%changelog
* Sun Oct 25 2026 Chenlang Li <Cc1580155hsg@163.com> - 0.1.1-0.1.dev2262b0e
- Development build (NOT released): RPM packaging for RHEL 10.1 x86_64
- runtime: libfrr + zebra + vtysh; egp: egpd; isolated under /opt/historic-routing
