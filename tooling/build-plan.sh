#!/bin/sh
# Build plan — the one module that owns what CI builds inside the OpenWrt SDK
# and how. Everything derivable is derived from the package Makefiles in this
# feed (source names, tarball URLs, git-proto skips); the irreducible SDK
# workarounds live in the corelib table below. The workflow only supplies the
# matrix (env: FEED_NAME, OPENWRT_VERSION, ARCH) and the two
# secret-touching steps (key install, apk adbsign) — those never come in here.
#
# Subcommands:
#   plan                    hermetic dry-run: print the derived plan as
#                           line-oriented key=value grouped by [section]
#   register   <sdk-dir>    seed feeds.conf (luci + base + this repo),
#                           idempotent
#   corelibs   <sdk-dir>    sparse-checkout boost + openssl into this feed
#   install    <sdk-dir>    feeds update -a + install the derived source names
#   config     <sdk-dir>    write the .config seed and run make defconfig
#   prefetch   <sdk-dir>    pre-fetch declared tarballs into <sdk-dir>/dl/
#   compile    <sdk-dir>    build every source package in order, smoke-testing
#                           as it goes (binary checks + apk presence)
#   verify     <sdk-dir>    assert every apk landed in the arch feed dir
#
# The plan subcommand is the test surface: tooling/tests/build-plan.sh asserts
# it against this repo's own Makefiles, so editing a Makefile without updating
# the plan fails the fast Host tests job before any SDK is downloaded.

set -eu

FEED_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
FEED_NAME=${FEED_NAME:-openwrtfeeds}
OPENWRT_VERSION=${OPENWRT_VERSION:-}
ARCH=${ARCH:-}

# ---------------------------------------------------------------------------
# The corelib table — the only static package knowledge in the module.
#
# The SDK ships no core package sources and no build rules for ad-hoc
# package/libs additions, so packages needing core libs must have those libs
# pulled into THIS feed at CI time (feeds update then indexes them and the
# DEPENDS/PKG_BUILD_DEPENDS of the feed packages resolve). Two libs:
#   openssl  stuntman's +libopenssl dep; from the openwrt repo at the
#            release tag matching OPENWRT_VERSION. Built with engines OFF:
#            the devcrypto engine #includes crypto/cryptodev.h (kmod-cryptodev),
#            which the SDK lacks.
#   boost    stuntman's PKG_BUILD_DEPENDS:=boost/host; from the packages repo
#            at the ref the SDK itself pins (parsed from feeds.conf.default —
#            resolved in corelibs, shown as a strategy in plan). Also fetches
#            lang/python/python3-version.mk, boost's relative include.
# The same rows drive corelibs, the feeds-install extras and the .config seed.
#   golang   mihomo-alpha's PKG_BUILD_DEPENDS:=golang/host and its hard include
#            $(TOPDIR)/feeds/packages/lang/golang/golang-package.mk; borrowed
#            from the packages repo like boost (the packages feed itself stays
#            unregistered — see cmd_register). cmd_install additionally
#            exposes the borrowed tree at the canonical feeds/packages path
#            the hard include expects.
CORELIBS="openssl boost golang"
corelib_repo() {
	case "$1" in
	openssl) echo "https://github.com/openwrt/openwrt.git" ;;
	boost | golang) echo "https://github.com/openwrt/packages.git" ;;
	esac
}
corelib_ref() {
	# strategy-level in plan (may embed a ${VAR} template); concrete in corelibs
	case "$1" in
	openssl) echo 'openwrt-tag-v${OPENWRT_VERSION}' ;;
	boost | golang) echo "packages-feed-pinned" ;;
	esac
}
corelib_path() {
	case "$1" in
	openssl) echo "package/libs/openssl" ;;
	boost) echo "libs/boost" ;;
	golang) echo "lang/golang" ;;
	esac
}
# where the lib lands INSIDE this feed (differs from the repo path for
# openssl: openwrt keeps it at package/libs/openssl, this feed wants libs/)
corelib_dest() {
	case "$1" in
	openssl) echo "libs/openssl" ;;
	boost) echo "libs/boost" ;;
	golang) echo "lang/golang" ;;
	esac
}
corelib_extra() {
	case "$1" in
	openssl) echo "" ;;
	boost) echo "lang/python/python3-version.mk" ;;
	golang) echo "" ;; # self-contained bundle: golang/ + *.mk siblings
	esac
}
corelib_installname() {
	case "$1" in
	openssl) echo "libopenssl" ;;
	boost) echo "boost" ;;
	golang) echo "golang" ;;
	esac
}
corelib_config() {
	case "$1" in
	openssl) printf 'CONFIG_PACKAGE_libopenssl=y\n# CONFIG_OPENSSL_ENGINE is not set\n' ;;
	boost) echo "" ;;
	golang) echo "" ;; # golang/host is dependency-triggered, never selected
	esac
}
corelib_probe() {
	# the file that proves the borrow landed (openssl/boost are single
	# package dirs with a Makefile; golang is a bundle rooted at a .mk file)
	case "$1" in
	golang) echo "golang-package.mk" ;;
	*) echo "Makefile" ;;
	esac
}

# ---------------------------------------------------------------------------
# There is no second feed. The nikki stack used to arrive through a pinned
# src-git bridge (2017fighting/OpenWrt-nikki); docs/adr/0001 removed it and
# brought mihomo-alpha's package definition into this repo instead. Everything
# CI builds now comes from this feed's own Makefiles, plus the borrowed golang.

# ---------------------------------------------------------------------------
# Derivation from the feed's own Makefiles.

# _mkvar <makefile> <VAR> — first value of a VAR:= / VAR?= assignment
_mkvar() {
	sed -n "s/^$2[[:space:]]*[:?]*=[[:space:]]*//p" "$1" | head -n 1
}

# _expand <makefile> <string> — substitute $(VAR) references using the same
# Makefile's own assignments (bounded passes; nested vars like natmap's
# PKG_SOURCE -> PKG_SOURCE_SUBDIR -> PKG_UPSTREAM_VERSION resolve fine).
# $(call ...) or unknown vars die loudly rather than emit a broken URL.
_expand() {
	local mf="$1" s="$2" v val i=0
	while printf '%s' "$s" | grep -q '\$([A-Za-z_]'; do
		i=$((i + 1))
		[ "$i" -le 8 ] || die "cannot expand '$s' (unresolved Make variables)"
		for v in $(printf '%s\n' "$s" |
			sed -n 's/.*\$(\([A-Za-z_][A-Za-z0-9_]*\)).*/\1/p' |
			sort -u); do
			val="$(_mkvar "$mf" "$v")"
			[ -n "$val" ] || die "$mf: no value for \$($v) while expanding '$s'"
			s=$(printf '%s' "$s" | sed "s|\$($v)|$val|g")
		done
	done
	printf '%s' "$s"
}

# _packages — derived source package names: every dir under net/ and luci/
# with a Makefile. Splits register through their source package, so only the
# source names ever need installing.
_packages() {
	local d
	for d in "$FEED_ROOT"/net/*/ "$FEED_ROOT"/luci/*/; do
		if [ -f "$d/Makefile" ]; then basename "$d"; fi
	done
	return 0
}

# Compile order. The set is derived (plan warns about anything unlisted); the
# order is curated — the proven sequence, each luci app after its service
# package. mihomo-bare 紧跟它依赖的核 mihomo-alpha：同一次构建先出核再出外壳。
COMPILE_ORDER="natmapt stuntman luci-app-natmapt mihomo-alpha mihomo-bare"

# _prefetch <makefile> <pkg> — emit url=/dest= for one tarball package; skip
# git-sourced packages (the SDK clones those itself). Git variant = the FIRST
# PKG_SOURCE_URL assignment ends in .git.
#
# The URL is read rather than PKG_MIRROR_HASH on purpose: mihomo-alpha drops the
# mirror hash deliberately (a git tarball's sha256 cannot be computed offline,
# so keeping it would cost one doomed CI run per bump — see its Makefile), and
# PKG_SOURCE_PROTO alone is unreliable because a tarball-vs-git ifeq/else pair
# (natmapt's) declares PROTO:=git only inside the git branch, so a
# first-assignment PROTO read would misclassify the tarball branch as git. In
# such a pair the first URL is the tarball one, which is what this rule wants.
_prefetch() {
	local mf="$1" pkg="$2" url src
	case "$(_mkvar "$mf" PKG_SOURCE_URL)" in
	*.git) return 0 ;;
	esac
	url=$(_expand "$mf" "$(_mkvar "$mf" PKG_SOURCE_URL)") || return 0
	src=$(_expand "$mf" "$(_mkvar "$mf" PKG_SOURCE)") || return 0
	[ -n "$url" ] && [ -n "$src" ] || return 0
	case "${url##*/}" in
	*.tar.gz | *.tgz | *.tar.xz | *.tar.bz2 | *.zip) ;; # URL already names the tarball
	*) url="$url/$src" ;;                               # dir-style URL: append the filename
	esac
	printf '%s|%s|dl/%s\n' "$pkg" "$url" "$src"
}

# ---------------------------------------------------------------------------
# Helpers

die() {
	echo "build-plan: $*" >&2
	exit 1
}
step() {
	echo
	echo "==> build-plan: $*"
	echo
}
_header() { echo "[$1]"; }

# ---------------------------------------------------------------------------
# Subcommands

cmd_plan() {
	local pkg lib unlisted=""
	_header feed
	echo "feed_name=$FEED_NAME"
	echo "feed_root=$FEED_ROOT"
	echo "src_link=src-link $FEED_NAME $FEED_ROOT"
	echo "feeds_conf_policy=luci+base+this-feed"

	_header corelibs
	for lib in $CORELIBS; do
		echo "corelib.$lib.repo=$(corelib_repo "$lib")"
		echo "corelib.$lib.ref=$(corelib_ref "$lib")"
		echo "corelib.$lib.path=$(corelib_path "$lib")"
		echo "corelib.$lib.feed_dest=$(corelib_dest "$lib")"
		echo "corelib.$lib.extra=$(corelib_extra "$lib")"
	done

	_header install
	echo "install.extras=$(for lib in $CORELIBS; do corelib_installname "$lib"; done | tr '\n' ' ')"
	for pkg in $(_packages); do echo "install.package=$pkg"; done

	_header config
	for lib in $CORELIBS; do corelib_config "$lib"; done

	_header prefetch
	pairs=$(for pkg in $(_packages); do
		if [ -f "$FEED_ROOT/net/$pkg/Makefile" ]; then
			_prefetch "$FEED_ROOT/net/$pkg/Makefile" "$pkg"
		fi
	done)
	printf '%s\n' "$pairs" | while IFS='|' read -r pkg u d; do
		printf 'prefetch.%s.url=%s\nprefetch.%s.dest=%s\n' "$pkg" "$u" "$pkg" "$d"
	done

	_header compile
	for pkg in $COMPILE_ORDER; do
		echo "compile.target=package/feeds/$FEED_NAME/$pkg/compile"
	done
	for pkg in $(_packages); do
		case " $COMPILE_ORDER " in
		*" $pkg "*) ;;
		*) unlisted="$unlisted $pkg" ;;
		esac
	done
	[ -z "$unlisted" ] || echo "compile.unlisted=$unlisted (add to COMPILE_ORDER)"

	_header verify
	echo "verify.out=bin/packages/\${ARCH}/$FEED_NAME"
	for g in natmapt stuntman-client luci-app-natmapt mihomo-alpha mihomo-bare; do
		echo "verify.apk=$g-*.apk"
	done
}

cmd_register() {
	local sdk="$1" conf="$1/feeds.conf"
	step "register feed (luci + base + this repo)"
	# The SDK ships feeds.conf.default (base/packages/luci/...) but no
	# feeds.conf. Seed it with luci AND base only:
	#   luci  luci.mk apps (luci-app-natmapt includes feeds/luci/luci.mk).
	#   base  the openwrt main repo itself (--root=package): provides the
	#         core packages (rpcd, ucode, libnl-tiny, lua, libubox, ...) that
	#         the +luci-base closure of a luci.mk app force-builds — without
	#         base, lucihttp/ucode-mod-html/rpcd-mod-luci die on missing
	#         headers. Their apks land in bin/packages/<arch>/{luci,base}/,
	#         outside this feed's published dir (same as the kmods).
	# The 'packages' feed is deliberately NOT registered — doing so would
	# make curl/bash/coreutils-timeout buildable, forcing CI to build them
	# (they need core libs the SDK lacks). Kept unregistered, they are
	# runtime-only deps: the apk declares them and the device auto-installs
	# them from its own repos.
	if [ ! -f "$conf" ]; then
		# NB: the base line carries an option field: "src-git --root=package
		# base <url>" — awk's $2 is "--root=package", the feed name sits in
		# $3. Match both shapes.
		awk '
			$2 == "luci" || $2 == "base" || ($2 == "--root=package" && $3 == "base") {print}
		' "$sdk/feeds.conf.default" >"$conf" 2>/dev/null || true
		[ -s "$conf" ] || cp "$sdk/feeds.conf.default" "$conf"
	fi
	grep -qxF "src-link $FEED_NAME $FEED_ROOT" "$conf" ||
		printf 'src-link %s %s\n' "$FEED_NAME" "$FEED_ROOT" >>"$conf"
	echo "--- feeds.conf ---"
	cat "$conf"
}

cmd_corelibs() {
	local sdk="$1" lib repo ref path dest extra tmp
	for lib in $CORELIBS; do
		repo=$(corelib_repo "$lib")
		path=$(corelib_path "$lib")
		extra=$(corelib_extra "$lib")
		step "pull $lib into this feed ($path)"
		tmp=$(mktemp -d)
		case $lib in
		openssl)
			[ -n "$OPENWRT_VERSION" ] || die "OPENWRT_VERSION is required for the openssl corelib"
			ref="v$OPENWRT_VERSION"
			git clone --depth 1 --branch "$ref" --filter=blob:none --sparse "$repo" "$tmp"
			git -C "$tmp" sparse-checkout set "$path"
			;;
		boost | golang)
			# The ref the SDK's own feeds.conf.default pins for the packages
			# feed — build against exactly what this SDK expects.
			ref=$(sed -nE 's@^src-git packages .*(\^|;)([^ ]+).*@\2@p' "$sdk/feeds.conf.default" | head -1)
			[ -n "$ref" ] || ref=master
			echo "packages feed ref: $ref"
			git init -q "$tmp"
			git -C "$tmp" remote add origin "$repo"
			git -C "$tmp" sparse-checkout init --cone
			git -C "$tmp" sparse-checkout set "$path"
			git -C "$tmp" fetch --depth 1 origin "$ref"
			git -C "$tmp" checkout -q FETCH_HEAD
			;;
		esac
		test -f "$tmp/$path/$(corelib_probe "$lib")" || die "$lib: $path/$(corelib_probe "$lib") not found at ref $ref"
		dest="$FEED_ROOT/$(corelib_dest "$lib")"
		mkdir -p "$(dirname "$dest")"
		rm -rf "$dest"
		cp -r "$tmp/$path" "$dest"
		if [ -n "$extra" ]; then
			# boost's Makefile includes this sibling file (385 bytes,
			# self-contained); fetch it so the relative include resolves
			# outside the packages feed tree.
			mkdir -p "$FEED_ROOT/$(dirname "$extra")"
			curl -fsSL "https://raw.githubusercontent.com/openwrt/packages/$ref/$extra" \
				-o "$FEED_ROOT/$extra"
			test -f "$FEED_ROOT/$extra" || die "$lib: extra file $extra missing"
		fi
		rm -rf "$tmp"
	done
}

cmd_install() {
	local sdk="$1" names="" lib pkg
	for lib in $CORELIBS; do names="$names $(corelib_installname "$lib")"; done
	for pkg in $(_packages); do names="$names $pkg"; done
	step "feeds update + install:$names"
	(
		cd "$sdk"
		# mihomo-alpha's Makefile hard-includes
		# $(TOPDIR)/feeds/packages/lang/golang/golang-package.mk — the canonical
		# path into the packages feed we deliberately never register. The golang
		# corelib is borrowed into THIS feed; expose it at the canonical path.
		# MUST run before feeds update: update-time metadata dumps parse every
		# feed Makefile, and a failed include silently drops the package from
		# the index (feeds install then skips it without failing).
		mkdir -p feeds/packages/lang
		ln -sfn "$FEED_ROOT/lang/golang" feeds/packages/lang/golang
		./scripts/feeds update -a
		# names are whitespace-separated words by construction
		# shellcheck disable=SC2086
		./scripts/feeds install $names
		# feeds install silently skips a name missing from every feed index —
		# fail HERE, not five minutes later at compile. Split packages
		# (libopenssl -> openssl, natmapt's script splits) stage under their
		# SOURCE name, so assert on the source set.
		for pkg in openssl boost golang $(_packages); do
			ls -d "$sdk"/package/feeds/*/$pkg >/dev/null 2>&1 ||
				die "feeds install did not stage $pkg (metadata dump or name mismatch)"
		done
	)
}

cmd_config() {
	local sdk="$1"
	step "seed .config + defconfig"
	{
		for lib in $CORELIBS; do corelib_config "$lib"; done
	} >"$sdk/.config"
	(cd "$sdk" && make defconfig)
	grep -E 'CONFIG_OPENSSL_ENGINE|CONFIG_PACKAGE_libopenssl' "$sdk/.config" || true
}

cmd_prefetch() {
	local sdk="$1" pkg mf u dest pairs
	step "pre-fetch declared tarballs into dl/"
	# The SDK's default fetcher only probes the OpenWrt source mirrors (which
	# 404 for custom packages). Pre-populate dl/ with the exact tarball each
	# Makefile declares; PKG_HASH verifies it on extract. The pairs come from
	# the same derivation plan prints (never a second copy of the URLs).
	mkdir -p "$sdk/dl"
	pairs=$(for pkg in $(_packages); do
		mf="$FEED_ROOT/net/$pkg/Makefile"
		[ -f "$mf" ] || continue
		_prefetch "$mf" "$pkg"
	done)
	printf '%s\n' "$pairs" | while IFS='|' read -r pkg u dest; do
		echo "fetch $u -> $sdk/$dest"
		curl -fL "$u" -o "$sdk/$dest"
		sha256sum "$sdk/$dest"
	done
}

cmd_compile() {
	local sdk="$1" pkg bin out pkgdir ver
	[ -n "$ARCH" ] || die "ARCH is required for compile/verify"
	out="$sdk/bin/packages/$ARCH/$FEED_NAME"
	for pkg in $COMPILE_ORDER; do
		step "build $pkg"
		case $pkg in
		natmapt)
			# One Makefile = natmapt + 5 PKGARCH:=all script splits; building
			# the SOURCE package compiles and packages all of them (splits
			# share the source dir, no separate compile targets).
			(cd "$sdk" && make "package/feeds/$FEED_NAME/natmapt/compile" -j"$(nproc)" V=s)
			# Smoke the .pkgdir copy (the SDK's AUTOREMOVE deletes the pristine
			# build output after packaging — see the mihomo-alpha branch).
			bin=$(find "$sdk/build_dir" -type f -path '*/natmap-*/.pkgdir/natmapt/usr/bin/natmap' | head -1)
			[ -n "$bin" ] || die "natmap binary not found in build_dir (expected the .pkgdir copy)"
			# Target-arch C binary: do NOT exec it (it binds ports and would
			# hang the runner) — confirm it compiled to ELF.
			file "$bin" | grep -q ELF || die "natmap smoke: $bin is not an ELF binary"
			file "$bin"
			;;
		stuntman)
			# feeds install maps the stuntman-client split onto its PKG_NAME
			# source; stuntman/compile builds the client/server/testcode
			# splits. Git source — the SDK clones it, no dl/ pre-fetch. Its
			# PKG_BUILD_DEPENDS:=boost/host and +libopenssl resolve to the
			# corelibs pulled into this feed.
			(cd "$sdk" && make "package/feeds/$FEED_NAME/stuntman/compile" -j"$(nproc)" V=s)
			ls -l "$out"/stuntman-client-*.apk
			;;
		luci-app-natmapt)
			(cd "$sdk" && make "package/feeds/$FEED_NAME/luci-app-natmapt/compile" -j"$(nproc)" V=s)
			ls -l "$out"/luci-app-natmapt-*.apk
			;;
		mihomo-alpha)
			# This feed's own package now (docs/adr/0001), git-sourced from the
			# pinned upstream Alpha commit (the SDK clones it itself — no dl/
			# pre-fetch). golang/host comes from the golang corelib. Check ELF +
			# the exact embedded version string, never exec a target-arch binary.
			(cd "$sdk" && make "package/feeds/$FEED_NAME/mihomo-alpha/compile" -j"$(nproc)" V=s)
			# After a successful build OpenWrt AUTOREMOVES the package build dir
			# (only .pkgdir — the installed file tree — and stamp files survive),
			# so search the whole package dir: the binary sits at
			# .pkgdir/mihomo-alpha/usr/libexec/mihomo (and in .go_work/build/bin
			# if autoremove policy ever changes).
			bin=$(find "$sdk/build_dir"/target-*/mihomo-alpha-*/ \
				-type f -name mihomo 2>/dev/null | head -1)
			[ -n "$bin" ] || die "mihomo binary not found in build_dir"
			file "$bin" | grep -q ELF || die "mihomo smoke: $bin is not an ELF binary"
			# 断言串从 Makefile 现读（不在这里抄一份）：PKG_BUILD_VERSION 就是
			# 核里嵌的 alpha-<sha7>，它同时证明「拉到的是钉住的 commit」而不是缓存旧包。
			ver=$(_mkvar "$FEED_ROOT/net/mihomo-alpha/Makefile" PKG_BUILD_VERSION)
			[ -n "$ver" ] || die "mihomo-alpha: PKG_BUILD_VERSION not found in its Makefile"
			strings "$bin" | grep -q "$ver" || die "mihomo smoke: version '$ver' not embedded in $bin"
			file "$bin"
			;;
		mihomo-bare)
			# Script-only package in THIS feed (no upstream, no compile step):
			# the make target just lays files into .pkgdir. Smoke the installed
			# tree instead of a binary — `sh -n` catches the class of error that
			# would otherwise only show up on the device at boot.
			(cd "$sdk" && make "package/feeds/$FEED_NAME/mihomo-bare/compile" -j"$(nproc)" V=s)
			ls -l "$out"/mihomo-bare-*.apk
			# 构建目录带版本号（mihomo-bare-<PKG_VERSION>），所以只匹配 .pkgdir 层
			pkgdir=$(find "$sdk/build_dir" -type d -path '*/.pkgdir/mihomo-bare' 2>/dev/null | head -1)
			[ -n "$pkgdir" ] || die "mihomo-bare: .pkgdir not found in build_dir"
			for f in etc/init.d/mihomo-bare usr/sbin/mihomo-bare-update etc/uci-defaults/90-mihomo-bare; do
				[ -f "$pkgdir/$f" ] || die "mihomo-bare smoke: missing $f"
				sh -n "$pkgdir/$f" || die "mihomo-bare smoke: $f fails sh -n"
			done
			[ -f "$pkgdir/etc/config/mihomo-bare" ] || die "mihomo-bare smoke: missing uci config"
			# 核路径必须与 mihomo-alpha 的实际安装位置一致（docs/adr/0001 删了
			# /usr/bin/mihomo 符号链接），且老设备的 conffile 靠 uci-defaults 迁移。
			grep -q "/usr/libexec/mihomo" "$pkgdir/etc/config/mihomo-bare" \
				|| die "mihomo-bare smoke: default core is not /usr/libexec/mihomo"
			grep -q "usr/bin/mihomo" "$pkgdir/etc/uci-defaults/90-mihomo-bare" \
				|| die "mihomo-bare smoke: uci-defaults lacks the /usr/bin/mihomo migration"
			# 回程豁免的 nft 文件:runner 上没有 CAP_NET_ADMIN,nft -c 跑不了,
			# 只验证存在 + 头部不是空文件 + 关键规则那行在(语法靠设备上首启验证)
			[ -s "$pkgdir/etc/mihomo-bare/reply-bypass.nft" ] || die "mihomo-bare smoke: missing reply-bypass.nft"
			grep -q 'ct direction reply' "$pkgdir/etc/mihomo-bare/reply-bypass.nft" \
				|| die "mihomo-bare smoke: reply-bypass.nft lacks the ct direction reply rule"
			head -1 "$pkgdir/etc/init.d/mihomo-bare" | grep -q '^#!/bin/sh /etc/rc.common' \
				|| die "mihomo-bare smoke: init shebang is not the rc.common form"
			;;
		*) die "no compile recipe for $pkg (extend cmd_compile)" ;;
		esac
	done
}

cmd_verify() {
	local sdk="$1" out g fails=0
	[ -n "$ARCH" ] || die "ARCH is required for compile/verify"
	out="$sdk/bin/packages/$ARCH/$FEED_NAME"
	step "verify apks in $out"
	for g in natmapt stuntman-client luci-app-natmapt mihomo-alpha mihomo-bare; do
		# natmapt-* also covers its script splits; the rest are one apk each
		# (or PKGARCH:=all, indexed under every arch slice).
		ls -l "$out"/$g-*.apk || fails=$((fails + 1))
	done
	[ "$fails" -eq 0 ] || die "$fails package group(s) missing from $out"
}

case "${1:-}" in
plan) cmd_plan ;;
register)
	[ $# -eq 2 ] || die "usage: build-plan.sh register <sdk-dir>"
	cmd_register "$2"
	;;
corelibs)
	[ $# -eq 2 ] || die "usage: build-plan.sh corelibs <sdk-dir>"
	cmd_corelibs "$2"
	;;
install)
	[ $# -eq 2 ] || die "usage: build-plan.sh install <sdk-dir>"
	cmd_install "$2"
	;;
config)
	[ $# -eq 2 ] || die "usage: build-plan.sh config <sdk-dir>"
	cmd_config "$2"
	;;
prefetch)
	[ $# -eq 2 ] || die "usage: build-plan.sh prefetch <sdk-dir>"
	cmd_prefetch "$2"
	;;
compile)
	[ $# -eq 2 ] || die "usage: build-plan.sh compile <sdk-dir>"
	cmd_compile "$2"
	;;
verify)
	[ $# -eq 2 ] || die "usage: build-plan.sh verify <sdk-dir>"
	cmd_verify "$2"
	;;
*) die "usage: build-plan.sh plan|register|corelibs|install|config|prefetch|compile|verify <sdk-dir>" ;;
esac
