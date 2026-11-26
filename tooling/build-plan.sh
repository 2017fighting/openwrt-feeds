#!/bin/sh
# Build plan — the one module that owns what CI builds inside the OpenWrt SDK
# and how. Everything derivable is derived from the package Makefiles in this
# feed (source names, tarball URLs, git-proto skips); the irreducible SDK
# workarounds live in the corelib table below. The workflow only supplies the
# matrix (env: FEED_NAME, ARCH) and the two secret-touching steps (key
# install, apk adbsign) — those never come in here.
#
# Subcommands:
#   plan                    hermetic dry-run: print the derived plan as
#                           line-oriented key=value grouped by [section]
#   register   <sdk-dir>    seed feeds.conf (base + this repo),
#                           idempotent
#   corelibs   <sdk-dir>    sparse-checkout the corelib table (golang) into this feed
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
ARCH=${ARCH:-}

# ---------------------------------------------------------------------------
# The corelib table — the only static package knowledge in the module.
#
# The SDK ships no core package sources and no build rules for ad-hoc
# package/libs additions, so packages needing core libs must have those libs
# pulled into THIS feed at CI time (feeds update then indexes them and the
# DEPENDS/PKG_BUILD_DEPENDS of the feed packages resolve). One lib is left —
# docs/adr/0002 retired stuntman, and with it the boost/openssl pair:
#   golang   punchd's PKG_BUILD_DEPENDS:=golang/host and its hard include
#            $(TOPDIR)/feeds/packages/lang/golang/golang-package.mk; borrowed
#            from the packages repo at the ref the SDK itself pins (parsed
#            from feeds.conf.default — resolved in corelibs, shown as a
#            strategy in plan), because the packages feed itself stays
#            unregistered — see cmd_register. cmd_install additionally
#            exposes the borrowed tree at the canonical feeds/packages path
#            the hard include expects.
# The same rows drive corelibs, the feeds-install extras and the .config seed.
CORELIBS="golang"
corelib_repo() {
	case "$1" in
	golang) echo "https://github.com/openwrt/packages.git" ;;
	esac
}
corelib_ref() {
	# strategy-level in plan; concrete in corelibs
	case "$1" in
	golang) echo "packages-feed-pinned" ;;
	esac
}
corelib_path() {
	case "$1" in
	golang) echo "lang/golang" ;;
	esac
}
# where the lib lands INSIDE this feed
corelib_dest() {
	case "$1" in
	golang) echo "lang/golang" ;;
	esac
}
corelib_extra() {
	case "$1" in
	golang) echo "" ;; # self-contained bundle: golang/ + *.mk siblings
	esac
}
corelib_installname() {
	case "$1" in
	golang) echo "golang" ;;
	esac
}
corelib_config() {
	case "$1" in
	golang) echo "" ;; # golang/host is dependency-triggered, never selected
	esac
}
corelib_probe() {
	# the file that proves the borrow landed (golang is a bundle rooted at a .mk file)
	case "$1" in
	golang) echo "golang-package.mk" ;;
	*) echo "Makefile" ;;
	esac
}

# ---------------------------------------------------------------------------
# There is no second feed. The nikki stack used to arrive through a pinned
# src-git bridge (2017fighting/OpenWrt-nikki); docs/adr/0001 removed it, and
# docs/adr/0002 later retired the mihomo/natmapt/stuntman packages altogether.
# Everything CI builds now comes from this feed's own Makefile (punchd), plus
# the borrowed golang toolchain.

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

# _packages — derived source package names: every dir under net/ with a
# Makefile. Splits register through their source package, so only the source
# names ever need installing. (A luci app would live under luci/ and also need
# the luci feed registered in cmd_register — docs/adr/0002 retired the last one.)
_packages() {
	local d
	for d in "$FEED_ROOT"/net/*/; do
		if [ -f "$d/Makefile" ]; then basename "$d"; fi
	done
	return 0
}

# Compile order. The set is derived (plan warns about anything unlisted); the
# order is curated — the proven sequence (a luci app would follow the service
# package it drives). punchd is the only package left (docs/adr/0002); it
# builds against the borrowed golang/host from the corelib table.
COMPILE_ORDER="punchd"

# _prefetch <makefile> <pkg> — emit url=/dest= for one tarball package; skip
# git-sourced packages (the SDK clones those itself). Git variant = the FIRST
# PKG_SOURCE_URL assignment ends in .git.
#
# The URL is read rather than PKG_MIRROR_HASH on purpose: git-sourced packages
# drop the mirror hash deliberately (a git tarball's sha256 cannot be computed
# offline, so keeping it would cost one doomed CI run per bump — see
# net/punchd/Makefile), and PKG_SOURCE_PROTO alone is unreliable because a
# tarball-vs-git ifeq/else pair declares PROTO:=git only inside the git branch,
# so a first-assignment PROTO read would misclassify the tarball branch as git.
# In such a pair the first URL is the tarball one, which is what this rule wants.
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
	echo "feeds_conf_policy=base+this-feed"

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
	for pkg in $(_packages); do
		if [ -f "$FEED_ROOT/net/$pkg/Makefile" ]; then
			_prefetch "$FEED_ROOT/net/$pkg/Makefile" "$pkg"
		fi
	done | while IFS='|' read -r pkg u d; do
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
	for g in punchd; do
		echo "verify.apk=$g-*.apk"
	done
}

cmd_register() {
	local sdk="$1" conf="$1/feeds.conf"
	step "register feed (base + this repo)"
	# The SDK ships feeds.conf.default (base/packages/luci/...) but no
	# feeds.conf. Seed it with base only:
	#   base  the openwrt main repo itself (--root=package): punchd's
	#         +firewall4 resolves there, so CI really builds the firewall4 the
	#         apk declares. Its apk lands in bin/packages/<arch>/base/, outside
	#         this feed's published dir (same as the kmods).
	# luci used to be registered for luci-app-natmapt; docs/adr/0002 removed
	# that app, and nothing here includes feeds/luci/luci.mk any more.
	# The 'packages' feed is deliberately NOT registered — doing so would make
	# natmap/ca-bundle buildable and force CI to build them. Kept unregistered,
	# they are runtime-only deps: the apk declares them and the device
	# auto-installs them from its own repos.
	if [ ! -f "$conf" ]; then
		# NB: the base line carries an option field: "src-git --root=package
		# base <url>" — awk's $2 is "--root=package", the feed name sits in
		# $3. Match both shapes.
		awk '
			$2 == "base" || ($2 == "--root=package" && $3 == "base") {print}
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
		golang)
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
			# a corelib may declare a sibling file its Makefile includes
			# (boost needed lang/python/python3-version.mk); fetch it so the
			# relative include resolves outside the packages feed tree.
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
		# punchd's Makefile hard-includes
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
		# fail HERE, not five minutes later at compile. Splits stage under their
		# SOURCE name, so assert on the source set.
		for pkg in golang $(_packages); do
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
}

cmd_prefetch() {
	local sdk="$1" pkg mf u dest
	step "pre-fetch declared tarballs into dl/"
	# The SDK's default fetcher only probes the OpenWrt source mirrors (which
	# 404 for custom packages). Pre-populate dl/ with the exact tarball each
	# Makefile declares; PKG_HASH verifies it on extract. The pairs come from
	# the same derivation plan prints (never a second copy of the URLs).
	mkdir -p "$sdk/dl"
	for pkg in $(_packages); do
		mf="$FEED_ROOT/net/$pkg/Makefile"
		[ -f "$mf" ] || continue
		_prefetch "$mf" "$pkg"
	done | while IFS='|' read -r pkg u dest; do
		echo "fetch $u -> $sdk/$dest"
		curl -fL "$u" -o "$sdk/$dest"
		sha256sum "$sdk/$dest"
	done
}

cmd_compile() {
	local sdk="$1" pkg bin out pkgdir
	[ -n "$ARCH" ] || die "ARCH is required for compile/verify"
	out="$sdk/bin/packages/$ARCH/$FEED_NAME"
	for pkg in $COMPILE_ORDER; do
		step "build $pkg"
		case $pkg in
		punchd)
			# 本 feed 唯一的包（docs/adr/0002；home-ops ADR-0044 的路由器侧）：git 源按
			# commit 钉住，SDK 自己 clone（无 dl/ 预取）；golang/host 来自 corelib 表。
			(cd "$sdk" && make "package/feeds/$FEED_NAME/punchd/compile" -j"$(nproc)" V=s)
			ls -l "$out"/punchd-*.apk
			# 构建目录带版本号（punchd-<PKG_VERSION>），冒烟看 .pkgdir 整棵树。
			pkgdir=$(find "$sdk/build_dir" -type d -path '*/.pkgdir/punchd' 2>/dev/null | head -1)
			[ -n "$pkgdir" ] || die "punchd: .pkgdir not found in build_dir"
			bin="$pkgdir/usr/bin/punchd"
			[ -f "$bin" ] || die "punchd smoke: $bin is missing (the Go install path moved?)"
			# Target-arch Go 二进制：绝不 exec（它要连集群、起 natmap、写 nft），
			# 只认 ELF + 一条只有 agent 才有的特征串 —— fw4 的 include 路径只出现在
			# internal/agent，所以它同时证明装的是 punchd 而不是集群那一半。
			file "$bin" | grep -q ELF || die "punchd smoke: $bin is not an ELF binary"
			strings "$bin" | grep -q '/usr/share/nftables.d/ruleset-post' \
				|| die "punchd smoke: the fw4 include path is not embedded in $bin"
			file "$bin"
			# 脚本/配置冒烟：init 语法 + conffile 在位。另外断言包里没有 token ——
			# 凭据是设备本地的，一旦被谁掉进 files/ 就是事故。
			sh -n "$pkgdir/etc/init.d/punchd" || die "punchd smoke: init fails sh -n"
			head -1 "$pkgdir/etc/init.d/punchd" | grep -q '^#!/bin/sh /etc/rc.common' \
				|| die "punchd smoke: init shebang is not the rc.common form"
			for f in etc/punch/punch.conf etc/punch/token.example; do
				[ -f "$pkgdir/$f" ] || die "punchd smoke: missing $f"
			done
			if [ -e "$pkgdir/etc/punch/token" ]; then
				die "punchd smoke: a token was packaged — credentials are device-local only"
			fi
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
	for g in punchd; do
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
