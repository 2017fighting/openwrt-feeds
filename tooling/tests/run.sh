#!/bin/sh
# Host-side tests for the section status store (net/natmapt/files/status.sh).
#
# Two adapters make the seam real: the device's jshn/jsonfilter on one side,
# and the stubs below on the other. The jshn stub is sourced BEFORE
# status.sh (the module only sources the device jshn when json_init is not
# already defined); the jsonfilter stub is picked up via PATH.
#
# Usage: sh tooling/tests/run.sh   (from anywhere; POSIX sh, no deps)

set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)

# ---------------------------------------------------------------- sandbox
SANDBOX=$(mktemp -d) || exit 1
trap 'rm -rf "$SANDBOX"' EXIT INT TERM
PRIV="$SANDBOX/priv"
PUB="$SANDBOX/pub"
mkdir -p "$SANDBOX/bin"
export NATMAP_STATUS_PRIVATE_DIR="$PRIV"
export NATMAP_STATUS_PUBLIC_DIR="$PUB"
PATH="$SANDBOX/bin:$PATH"
export PATH

# ------------------------------------------------- jshn adapter (sourced)
# Minimal flat single-object JSON emitter: json_init/json_add_string/
# json_add_int/json_dump, the calls status.sh makes.
cat >"$SANDBOX/bin/jshn.sh" <<'EOF'
_J_ROWS=''
json_init() { _J_ROWS=''; }
_j_add() { _J_ROWS="${_J_ROWS:+${_J_ROWS},}\"$1\":$2"; }
json_add_string() {
	_j_add "$1" "\"$(printf '%s' "$2" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')\""
}
json_add_int() { _j_add "$1" "$2"; }
json_dump() { printf '{%s}\n' "$_J_ROWS"; }
EOF

# ---------------------------------------------- jsonfilter adapter (PATH)
# Supports only the form status.sh uses: -q -i <file> -e '@.<key>' for a
# top-level string key. Prints the value or nothing.
cat >"$SANDBOX/bin/jsonfilter" <<'EOF'
#!/bin/sh
file='' expr=''
while [ $# -gt 0 ]; do
	case "$1" in
		-i) file="$2"; shift 2 ;;
		-e) expr="$2"; shift 2 ;;
		*) shift ;;
	esac
done
key="${expr#@.}"
[ -n "$file" ] && [ -n "$key" ] || exit 1
# quoted string values first, then unquoted (json_add_int output)
sed -n -e "s/^.*[{,]\"$key\":\"\([^\"]*\)\"[,}].*$/\1/p" \
       -e "s/^.*[{,]\"$key\":\([^\",}\]*\)[,}].*$/\1/p" "$file" | head -n 1
EOF
chmod +x "$SANDBOX/bin/jsonfilter"

. "$SANDBOX/bin/jshn.sh"
. "$ROOT/net/natmapt/files/status.sh"

# --------------------------------------------------------- assertions
pass=0 fails=0
ok() {
	pass=$((pass + 1))
	echo "ok - $1"
}
bad() {
	fails=$((fails + 1))
	echo "NOT OK - $1"
}
assert_eq() { # <label> <got> <want>
	[ "$2" = "$3" ] && ok "$1" || bad "$1 (got '$2', want '$3')"
}
assert_mode() { # <label> <file> <mode>
	m=$(stat -c %a "$2" 2>/dev/null)
	assert_eq "$1" "$m" "$3"
}
field() { jsonfilter -q -i "$1" -e "@.$2"; } # via the stub, like status.sh

# ---- 1. publish writes both files with the frozen schema
status_publish cfg123 "my comment" hath 4242 1.2.3.4 55551 ::ffff:1.2.3.4 51413 tcp 192.168.1.10
assert_eq "private file is <pid>.json" "$(ls "$PRIV" 2>/dev/null)" "4242.json"
assert_eq "public file is <name>.json" "$(ls "$PUB" 2>/dev/null)" "hath.json"
assert_mode "private perms 600" "$PRIV/4242.json" 600
assert_mode "public perms 644" "$PUB/hath.json" 644
assert_eq "sid" "$(field "$PUB/hath.json" sid)" "cfg123"
assert_eq "comment" "$(field "$PUB/hath.json" comment)" "my comment"
assert_eq "ip" "$(field "$PUB/hath.json" ip)" "1.2.3.4"
assert_eq "ip4p" "$(field "$PUB/hath.json" ip4p)" "::ffff:1.2.3.4"
assert_eq "protocol" "$(field "$PUB/hath.json" protocol)" "tcp"
assert_eq "inner_ip" "$(field "$PUB/hath.json" inner_ip)" "192.168.1.10"
grep -q '"port":55551' "$PUB/hath.json" && ok "port serialized as int" || bad "port serialized as int"
grep -q '"inner_port":51413' "$PUB/hath.json" && ok "inner_port serialized as int" || bad "inner_port serialized as int"
assert_eq "public adds name" "$(field "$PUB/hath.json" name)" "hath"
assert_eq "public adds pid" "$(field "$PUB/hath.json" pid)" "4242"
grep -q '"name"' "$PRIV/4242.json" && bad "private has no name field" || ok "private has no name field"
grep -q '"pid"' "$PRIV/4242.json" && bad "private has no pid field" || ok "private has no pid field"
assert_eq "private sid matches" "$(field "$PRIV/4242.json" sid)" "cfg123"

# ---- 2. name sanitizing + sid fallback
status_publish cfgX '' ../evil 100 203.0.113.9 12345 '' 80 udp 192.168.1.2
assert_eq "path traversal neutralized" "$(ls "$PUB" | grep evil)" "evil.json"
assert_eq "traversed name field sanitized" "$(field "$PUB/evil.json" name)" "evil"
status_publish cfgY '' .hidden 101 203.0.113.9 12346 '' 81 udp 192.168.1.3
assert_eq "leading dots stripped (non-hidden)" "$(ls "$PUB" | grep hidden)" "hidden.json"
status_publish cfgZ '' '' 102 203.0.113.9 12347 '' 82 udp 192.168.1.4
assert_eq "empty name falls back to sid" "$(ls "$PUB" | grep cfgZ)" "cfgZ.json"
status_publish cfgW '' '全部' 103 203.0.113.9 12348 '' 83 udp 192.168.1.5
assert_eq "all-unsafe name falls back to sid" "$(ls "$PUB" | grep cfgW)" "cfgW.json"

# ---- 3. atomic writes leave no temp litter
litter=$(find "$PRIV" "$PUB" -name '*.json.??????' 2>/dev/null | wc -l | tr -d ' ')
assert_eq "no temp files left behind" "$litter" "0"

# ---- 4. respawn: clear-by-sid removes every file of that section
status_publish cfgA '' hath2 201 198.51.100.1 20001 '' 90 tcp 192.168.8.1
status_publish cfgA '' hath2 202 198.51.100.1 20002 '' 90 tcp 192.168.8.1
status_publish cfgB '' other 301 198.51.100.2 20003 '' 91 tcp 192.168.8.2
assert_eq "respawn left two private files for cfgA" \
	"$(ls "$PRIV" | grep -c '^20[12].json$')" "2"
status_clear cfgA
[ -e "$PRIV/201.json" ] || [ -e "$PRIV/202.json" ] || [ -e "$PUB/hath2.json" ] &&
	bad "every cfgA file removed" || ok "every cfgA file removed"
[ -f "$PRIV/301.json" ] && [ -f "$PUB/other.json" ] &&
	ok "cfgB untouched in both dirs" || bad "cfgB untouched in both dirs"
assert_eq "cfgB private file survives" "$(field "$PRIV/301.json" sid)" "cfgB"

# ---- 5. clear-all empties both dirs (any file type, like the old find)
touch "$PUB/note.txt" "$PRIV/stray.bin"
status_clear
left=$(find "$PRIV" "$PUB" -type f | wc -l | tr -d ' ')
assert_eq "clear-all removes every file" "$left" "0"

# ---- 6. arity guard: wrong arg count writes nothing, fails loudly
n_before=$(find "$PRIV" "$PUB" -type f | wc -l | tr -d ' ')
if status_publish cfg123 c n 1 2 3 4 5 6; then
	bad "wrong arity returns non-zero"
else
	ok "wrong arity returns non-zero"
fi
n_after=$(find "$PRIV" "$PUB" -type f | wc -l | tr -d ' ')
assert_eq "wrong arity writes nothing" "$n_after" "$n_before"

# ------------------------------------------------------------- summary
# ---- build plan suite (derived CI knowledge vs the Makefiles) ---------
. "$ROOT/tooling/tests/build-plan.sh"

echo "----------------------------------------"
echo "passed: $pass, failed: $fails"
[ "$fails" -eq 0 ]
