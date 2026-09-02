# Build plan suite — asserts `tooling/build-plan.sh plan` against this
# repo's OWN Makefiles, so the derived CI knowledge cannot drift from the
# declarations. Sourced by tooling/tests/run.sh (shares ok/bad/assert_eq and
# the counters). plan is hermetic: no SDK, no network, no env required.

BP="$ROOT/tooling/build-plan.sh"
plan=$(sh "$BP" plan 2>&1) || bad "plan exits cleanly"
bp_section() { echo "$plan" | awk -v s="[$1]" '$0==s{f=1;next} /^\[.*\]$/{f=0} f'; }

# ---- [feed]
assert_eq "feed name default" \
	"$(echo "$plan" | sed -n 's/^feed_name=//p')" "openwrtfeeds"
echo "$plan" | grep -q "^src_link=src-link openwrtfeeds $ROOT\$" &&
	ok "src_link points at the repo root" || bad "src_link points at the repo root"
assert_eq "feeds.conf policy" \
	"$(echo "$plan" | sed -n 's/^feeds_conf_policy=//p')" "luci+base+this-feed+nikki-bridge"

# ---- [corelibs] — strategy-level refs only (Q11)
c=$(bp_section corelibs)
assert_eq "openssl repo" "$(echo "$c" | sed -n 's/^corelib.openssl.repo=//p')" \
	"https://github.com/openwrt/openwrt.git"
assert_eq "openssl ref stays a strategy template" \
	"$(echo "$c" | sed -n 's/^corelib.openssl.ref=//p')" "openwrt-tag-v\${OPENWRT_VERSION}"
assert_eq "boost repo" "$(echo "$c" | sed -n 's/^corelib.boost.repo=//p')" \
	"https://github.com/openwrt/packages.git"
assert_eq "boost ref is the SDK-pinned strategy" \
	"$(echo "$c" | sed -n 's/^corelib.boost.ref=//p')" "packages-feed-pinned"
assert_eq "boost extra include" \
	"$(echo "$c" | sed -n 's/^corelib.boost.extra=//p')" "lang/python/python3-version.mk"
assert_eq "openssl feed landing spot is libs/ (not its repo path package/libs/)" \
	"$(echo "$c" | sed -n 's/^corelib.openssl.feed_dest=//p')" "libs/openssl"
assert_eq "boost feed landing spot" \
	"$(echo "$c" | sed -n 's/^corelib.boost.feed_dest=//p')" "libs/boost"
assert_eq "golang repo (borrowed like boost)" \
	"$(echo "$c" | sed -n 's/^corelib.golang.repo=//p')" "https://github.com/openwrt/packages.git"
assert_eq "golang ref is the SDK-pinned strategy" \
	"$(echo "$c" | sed -n 's/^corelib.golang.ref=//p')" "packages-feed-pinned"
assert_eq "golang stays at its repo path (bundle, not single package)" \
	"$(echo "$c" | sed -n 's/^corelib.golang.feed_dest=//p')" "lang/golang"

# ---- [bridge] — the pinned second feed carrying the nikki stack
b=$(bp_section bridge)
assert_eq "bridge repo" "$(echo "$b" | sed -n 's/^bridge.repo=//p')" \
	"https://github.com/2017fighting/OpenWrt-nikki.git"
assert_eq "bridge ref is a full commit sha (reproducible)" \
	"$(echo "$b" | sed -n 's/^bridge.ref=//p' | grep -cE '^[0-9a-f]{40}$')" "1"
got=$(echo "$b" | sed -n 's/^bridge.package=//p' | sort | tr '\n' ' ')
assert_eq "bridge package set" "$got" \
	"luci-app-nikki luci-i18n-nikki-zh-hans mihomo-alpha nikki "

# ---- [install] — derived source set + corelib extras
i=$(bp_section install)
assert_eq "corelib install extras" \
	"$(echo "$i" | sed -n 's/^install.extras=//p')" "libopenssl boost golang "
got=$(echo "$i" | sed -n 's/^install.package=//p' | sort | tr '\n' ' ')
assert_eq "install set == every Makefile dir under net/ and luci/" "$got" \
	"luci-app-mosdns luci-app-natmapt mosdns natmapt stuntman "
got=$(echo "$i" | sed -n 's/^install.bridge=//p' | tr '\n' ' ')
assert_eq "bridge packages join the install set (i18n split ships with its app source)" "$got" \
	"mihomo-alpha nikki luci-app-nikki "

# ---- [config] — engine-off fragment present verbatim
cfg=$(bp_section config)
echo "$cfg" | grep -qx 'CONFIG_PACKAGE_libopenssl=y' &&
	ok "config selects libopenssl" || bad "config selects libopenssl"
echo "$cfg" | grep -qx '# CONFIG_OPENSSL_ENGINE is not set' &&
	ok "config disables engines" || bad "config disables engines"

# ---- [prefetch] — derived from the Makefiles themselves
p=$(bp_section prefetch)
mosdns_ver=$(sed -n 's/^PKG_VERSION:=//p' "$ROOT/net/mosdns/Makefile" | head -1)
assert_eq "mosdns url == PKG_SOURCE_URL with PKG_VERSION expanded" \
	"$(echo "$p" | sed -n 's/^prefetch.mosdns.url=//p')" \
	"https://github.com/2017fighting/mosdns/archive/refs/tags/v$mosdns_ver.tar.gz"
assert_eq "mosdns dest == PKG_SOURCE with PKG_VERSION expanded" \
	"$(echo "$p" | sed -n 's/^prefetch.mosdns.dest=//p')" \
	"dl/mosdns-$mosdns_ver.tar.gz"
natmap_ver=$(sed -n 's/^PKG_UPSTREAM_VERSION:=//p' "$ROOT/net/natmapt/Makefile" | head -1)
assert_eq "natmap url derived (two-level Make var expansion)" \
	"$(echo "$p" | sed -n 's/^prefetch.natmapt.url=//p')" \
	"https://github.com/heiher/natmap/releases/download/$natmap_ver/natmap-$natmap_ver.tar.xz"
assert_eq "natmap dest derived" \
	"$(echo "$p" | sed -n 's/^prefetch.natmapt.dest=//p')" \
	"dl/natmap-$natmap_ver.tar.xz"
echo "$p" | grep -q '^prefetch.stuntman\.' &&
	bad "git-proto source skipped from prefetch" ||
	ok "git-proto source skipped from prefetch"

# ---- [compile] — curated order, no unlisted packages
c=$(bp_section compile)
got=$(echo "$c" | sed -n 's/^compile.target=package\/feeds\/[a-z]*\///p' | sed 's/\/compile$//' | tr '\n' ' ')
assert_eq "compile order" "$got" \
	"mosdns luci-app-mosdns natmapt stuntman luci-app-natmapt mihomo-alpha nikki luci-app-nikki "
echo "$c" | grep -qx 'compile.target=package/feeds/nikki/mihomo-alpha/compile' &&
	ok "bridge packages compile under the nikki feed target" ||
	bad "bridge packages compile under the nikki feed target"
echo "$c" | grep -q '^compile.bridge_relocate=nikki/' &&
	ok "bridge apk relocation is declared in the plan" ||
	bad "bridge apk relocation is declared in the plan"
echo "$c" | grep -q '^compile.unlisted=' &&
	bad "every derived package has a compile slot" ||
	ok "every derived package has a compile slot"
echo "$c" | grep -q '^compile.unlisted=' &&
	bad "every derived package has a compile slot" ||
	ok "every derived package has a compile slot"

# ---- env passthrough: GOARCH reaches the mosdns compile invocation
plan_arm=$(GOARCH=arm64 sh "$BP" plan 2>&1)
assert_eq "GOARCH env flows into the plan" \
	"$(echo "$plan_arm" | sed -n 's/^compile.env.mosdns=//p')" "MOSDNS_GOARCH=arm64"

# ---- [verify] — apk globs, natmapt-* covering its splits
v=$(bp_section verify)
gfail=0
for g in mosdns luci-app-mosdns natmapt stuntman-client luci-app-natmapt \
	mihomo-alpha nikki luci-app-nikki luci-i18n-nikki-zh-hans; do
	echo "$v" | grep -Fxq "verify.apk=$g-*.apk" || {
		bad "verify glob present: $g"
		gfail=1
	}
done
[ "$gfail" -eq 0 ] && ok "all nine verify globs present"

# ---- CLI guards
if sh "$BP" bogus >/dev/null 2>&1; then
	bad "unknown subcommand exits non-zero"
else
	ok "unknown subcommand exits non-zero"
fi
if sh "$BP" compile >/dev/null 2>&1; then
	bad "missing sdk-dir argument exits non-zero"
else
	ok "missing sdk-dir argument exits non-zero"
fi
