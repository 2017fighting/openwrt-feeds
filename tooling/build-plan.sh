#!/bin/sh
# Build plan — the one module that owns what CI builds inside the OpenWrt SDK
# and how. Everything derivable is derived from the package Makefiles in this
# feed (source names, tarball URLs, git-proto skips); the irreducible SDK
# workarounds live in the corelib table below. The workflow only supplies the
# matrix (env: FEED_NAME, OPENWRT_VERSION, ARCH, GOARCH) and the two
# secret-touching steps (key install, apk adbsign) — those never come in here.
#
# Subcommands:
#   plan                    hermetic dry-run: print the derived plan as
#                           line-oriented key=value grouped by [section]
#   register   <sdk-dir>    seed feeds.conf (luci only + this repo), idempotent
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
GOARCH=${GOARCH:-amd64}

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
CORELIBS="openssl boost"
corelib_repo() {
	case "$1" in
	openssl) echo "https://github.com/openwrt/openwrt.git" ;;
	boost) echo "https://github.com/openwrt/packages.git" ;;
	esac
}
corelib_ref() {
	# strategy-level in plan (may embed a ${VAR} template); concrete in corelibs
	case "$1" in
	openssl) echo 'openwrt-tag-v${OPENWRT_VERSION}' ;;
	boost) echo "packages-feed-pinned" ;;
	esac
}
corelib_path() {
	case "$1" in
	openssl) echo "package/libs/openssl" ;;
	boost) echo "libs/boost" ;;
	esac
}
corelib_extra() {
	case "$1" in
	openssl) echo "" ;;
	boost) echo "lang/python/python3-version.mk" ;;
	esac
}
corelib_installname() {
	case "$1" in
	openssl) echo "libopenssl" ;;
	boost) echo "boost" ;;
	esac
}
corelib_config() {
	case "$1" in
	openssl) printf 'CONFIG_PACKAGE_libopenssl=y\n# CONFIG_OPENSSL_ENGINE is not set\n' ;;
	boost) echo "" ;;
	esac
}

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
# package.
COMPILE_ORDER="mosdns luci-app-mosdns natmapt stuntman luci-app-natmapt"

# _prefetch <makefile> <pkg> — emit url=/dest= for one tarball package; skip
# git-sourced packages (the SDK clones those itself). Git variant = has
# PKG_MIRROR_HASH and no PKG_HASH: Makefiles with a tarball-vs-git ifeq/else
# pair (natmapt's) declare PROTO:=git only in the git branch, so a naive
# first-assignment PROTO read would misclassify the tarball branch as git.
_prefetch() {
	local mf="$1" pkg="$2" url src
	if [ -n "$(_mkvar "$mf" PKG_MIRROR_HASH)" ] && [ -z "$(_mkvar "$mf" PKG_HASH)" ]; then
		return 0
	fi
	url=$(_expand "$mf" "$(_mkvar "$mf" PKG_SOURCE_URL)") || return 0
	src=$(_expand "$mf" "$(_mkvar "$mf" PKG_SOURCE)") || return 0
	[ -n "$url" ] && [ -n "$src" ] || return 0
	case "${url##*/}" in
	*.tar.gz | *.tgz | *.tar.xz | *.tar.bz2 | *.zip) ;; # URL already names the tarball
	*) url="$url/$src" ;;                               # dir-style URL: append the filename
	esac
	printf 'prefetch.%s.url=%s\nprefetch.%s.dest=dl/%s\n' "$pkg" "$url" "$pkg" "$src"
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
	echo "feeds_conf_policy=luci-only+this-feed"

	_header corelibs
	for lib in $CORELIBS; do
		echo "corelib.$lib.repo=$(corelib_repo "$lib")"
		echo "corelib.$lib.ref=$(corelib_ref "$lib")"
		echo "corelib.$lib.path=$(corelib_path "$lib")"
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
	done

	_header compile
	for pkg in $COMPILE_ORDER; do
		echo "compile.target=package/feeds/$FEED_NAME/$pkg/compile"
		case $pkg in
		mosdns) echo "compile.env.mosdns=MOSDNS_GOARCH=$GOARCH" ;;
		esac
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
	for g in mosdns luci-app-mosdns natmapt stuntman-client luci-app-natmapt; do
		echo "verify.apk=$g-*.apk"
	done
}

cmd_register() {
	local sdk="$1" conf="$1/feeds.conf"
	step "register feed (luci only + this repo)"
	# The SDK ships feeds.conf.default (luci/packages/...) but no feeds.conf.
	# Seed it with luci ONLY: the 'packages' feed is deliberately NOT
	# registered — doing so would make curl/bash/coreutils-timeout buildable,
	# forcing CI to build them (they need core libs the SDK lacks). Kept
	# unregistered, they are runtime-only deps: the apk declares them and the
	# device auto-installs them from its own repos.
	if [ ! -f "$conf" ]; then
		awk '$2 == "luci" {print}' "$sdk/feeds.conf.default" >"$conf" 2>/dev/null || true
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
			;;
		boost)
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
		test -f "$tmp/$path/Makefile" || die "$lib: $path/Makefile not found at ref $ref"
		dest="$FEED_ROOT/$path"
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
		./scripts/feeds update -a
		# names are whitespace-separated words by construction
		# shellcheck disable=SC2086
		./scripts/feeds install $names
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
	local sdk="$1" plan pkg u dest
	step "pre-fetch declared tarballs into dl/"
	# The SDK's default fetcher only probes the OpenWrt source mirrors (which
	# 404 for custom packages). Pre-populate dl/ with the exact tarball each
	# Makefile declares; PKG_HASH verifies it on extract.
	mkdir -p "$sdk/dl"
	plan=$(FEED_ROOT="$FEED_ROOT" "$0" plan)
	echo "$plan" | sed -n 's/^prefetch\.\([^.]*\)\.url=/\1 /p' | while IFS=' ' read -r pkg u; do
		dest=$(echo "$plan" | sed -n "s/^prefetch\.$pkg\.dest=//p")
		[ -n "$dest" ] || die "prefetch: no dest for $pkg"
		echo "fetch $u -> $sdk/$dest"
		curl -fL "$u" -o "$sdk/$dest"
		sha256sum "$sdk/$dest"
	done
}

cmd_compile() {
	local sdk="$1" pkg bin out
	[ -n "$ARCH" ] || die "ARCH is required for compile/verify"
	out="$sdk/bin/packages/$ARCH/$FEED_NAME"
	for pkg in $COMPILE_ORDER; do
		step "build $pkg"
		case $pkg in
		mosdns)
			(cd "$sdk" && make "package/feeds/$FEED_NAME/mosdns/compile" MOSDNS_GOARCH="$GOARCH" -j"$(nproc)" V=s)
			bin=$(find "$sdk/build_dir" -path '*mosdns-*/mosdns' -type f | head -1)
			[ -n "$bin" ] || die "mosdns binary not found in build_dir"
			if [ "$GOARCH" = amd64 ]; then
				"$bin" version # runner is amd64 -> execute directly
			else
				file "$bin" # cross-arch binary; cannot exec on amd64 runner
			fi
			;;
		luci-app-mosdns)
			(cd "$sdk" && make "package/feeds/$FEED_NAME/luci-app-mosdns/compile" -j"$(nproc)" V=s)
			# The apk SDK packages the PKGARCH:=all luci-app directly into
			# each arch feed dir; assert presence before indexing.
			ls -l "$out"/luci-app-mosdns-*.apk
			;;
		natmapt)
			# One Makefile = natmapt + 5 PKGARCH:=all script splits; building
			# the SOURCE package compiles and packages all of them (splits
			# share the source dir, no separate compile targets).
			(cd "$sdk" && make "package/feeds/$FEED_NAME/natmapt/compile" -j"$(nproc)" V=s)
			bin=$(find "$sdk/build_dir" -path '*natmap-*/bin/natmap' -type f | head -1)
			[ -n "$bin" ] || die "natmap binary not found in build_dir"
			# Target-arch C binary: do NOT exec it (it binds ports and would
			# hang the runner) — just confirm it compiled to ELF.
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
		*) die "no compile recipe for $pkg (extend cmd_compile)" ;;
		esac
	done
}

cmd_verify() {
	local sdk="$1" out g fails=0
	[ -n "$ARCH" ] || die "ARCH is required for compile/verify"
	out="$sdk/bin/packages/$ARCH/$FEED_NAME"
	step "verify apks in $out"
	for g in mosdns luci-app-mosdns natmapt stuntman-client luci-app-natmapt; do
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
