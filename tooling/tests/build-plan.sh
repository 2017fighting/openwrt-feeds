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
# luci used to be registered for luci-app-natmapt; base is all punchd needs
# (+firewall4 resolves there). docs/adr/0002.
assert_eq "feeds.conf policy" \
	"$(echo "$plan" | sed -n 's/^feeds_conf_policy=//p')" "base+this-feed"

# ---- [corelibs] — punchd's golang toolchain is the only borrow left
c=$(bp_section corelibs)
assert_eq "corelib set (golang only after ADR 0002)" \
	"$(echo "$c" | sed -n 's/^corelib\.\([a-z]*\)\.repo=.*/\1/p' | sort | tr '\n' ' ')" \
	"golang "
assert_eq "golang repo (borrowed from the packages feed)" \
	"$(echo "$c" | sed -n 's/^corelib.golang.repo=//p')" "https://github.com/openwrt/packages.git"
assert_eq "golang ref is the SDK-pinned strategy" \
	"$(echo "$c" | sed -n 's/^corelib.golang.ref=//p')" "packages-feed-pinned"
assert_eq "golang stays at its repo path (bundle, not single package)" \
	"$(echo "$c" | sed -n 's/^corelib.golang.feed_dest=//p')" "lang/golang"

# ---- [no second feed] — the nikki bridge is gone (docs/adr/0001)
echo "$plan" | grep -q '^bridge\.' &&
	bad "no bridge section in the plan" || ok "no bridge section in the plan"
echo "$plan" | grep -q '^src-git ' &&
	bad "plan declares no src-git feed" || ok "plan declares no src-git feed"

# ---- [install] — derived source set + corelib extras
i=$(bp_section install)
assert_eq "corelib install extras" \
	"$(echo "$i" | sed -n 's/^install.extras=//p')" "golang "
got=$(echo "$i" | sed -n 's/^install.package=//p' | sort | tr '\n' ' ')
assert_eq "install set == every Makefile dir under net/" "$got" "punchd "

# ---- [config] — nothing to seed: golang/host is dependency-triggered
cfg=$(bp_section config)
assert_eq "config seed is empty" "$cfg" ""

# ---- [prefetch] — derived from the Makefiles themselves
p=$(bp_section prefetch)
# punchd carries no PKG_MIRROR_HASH on purpose: the git-source rule must read
# its PKG_SOURCE_URL (.git suffix), or CI would curl a git URL.
assert_eq "punchd source url is a .git url (the prefetch skip rule)" \
	"$(sed -n 's/^PKG_SOURCE_URL:=\(.*\.git\)$/\1/p' "$ROOT/net/punchd/Makefile" | head -1)" \
	"https://github.com/2017fighting/punch.git"
echo "$p" | grep -q '^prefetch.punchd\.' &&
	bad "punchd skipped from prefetch (git source, no mirror hash)" ||
	ok "punchd skipped from prefetch (git source, no mirror hash)"
# A branch would make "reproducible" a lie: the pin has to be a 40-hex sha.
assert_eq "punchd is pinned by a 40-hex commit sha" \
	"$(sed -n 's/^PKG_SOURCE_VERSION:=\([0-9a-f]\{40\}\)$/\1/p' "$ROOT/net/punchd/Makefile" | wc -l | tr -d ' ')" \
	"1"

# ---- [compile] — curated order, no unlisted packages
c=$(bp_section compile)
got=$(echo "$c" | sed -n 's/^compile.target=package\/feeds\/[a-z]*\///p' | sed 's/\/compile$//' | tr '\n' ' ')
assert_eq "compile order" "$got" "punchd "
echo "$c" | grep -q '^compile.target=package/feeds/nikki/' &&
	bad "no compile target under a bridge feed" ||
	ok "no compile target under a bridge feed"
echo "$c" | grep -q '^compile.unlisted=' &&
	bad "every derived package has a compile slot" ||
	ok "every derived package has a compile slot"

# ---- [verify] — one apk glob
v=$(bp_section verify)
assert_eq "verify globs == punchd only" \
	"$(echo "$v" | sed -n 's/^verify.apk=//p' | tr '\n' ' ')" "punchd-*.apk "

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
