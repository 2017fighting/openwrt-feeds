#!/bin/sh
# Host-side tests for the build plan module (tooling/build-plan.sh).
#
# Hermetic: `build-plan.sh plan` derives everything from this repo's own
# Makefiles, so the suite needs no SDK, no network and no env. It is the fast
# gate CI runs before the matrix build.
#
# Usage: sh tooling/tests/run.sh   (from anywhere; POSIX sh, no deps)

set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)

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

# ---- build plan suite (derived CI knowledge vs the Makefiles) ---------
. "$ROOT/tooling/tests/build-plan.sh"

echo "----------------------------------------"
echo "passed: $pass, failed: $fails"
[ "$fails" -eq 0 ]
