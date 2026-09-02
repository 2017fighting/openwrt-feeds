#!/bin/sh
# Section status store — the one module that owns the natmap section status
# files: schema, paths, filename sanitizing, permissions, atomic writes and
# cleanup. Sourced (not executed) by /etc/init.d/natmap and
# /usr/lib/natmap/update.sh.
#
# FROZEN CONTRACT (external consumers depend on this — extend, never change
# in place):
#   private file  ${NATMAP_STATUS_PRIVATE_DIR}/<pid>.json   mode 600
#                 consumed by /etc/init.d/natmap cleanup and luci-app-natmapt
#   public  file  ${NATMAP_STATUS_PUBLIC_DIR}/<name>.json   mode 644
#                 served by uhttpd over HTTP at /natmap/<name>.json as the
#                 query interface for other programs
#   shared fields sid, comment, ip, port (int), ip4p, inner_port (int),
#                 protocol, inner_ip
#   public adds   name, pid (both strings, as originally serialized)
#   <name>        the section's UCI "name" option, sanitized: unsafe chars
#                 -> '_', leading [._-] stripped (path-traversal-safe, and
#                 non-hidden so clear-all still sees it); empty/all-unsafe
#                 -> the section id
#   atomicity     every file is staged as a temp file beside its target and
#                 renamed into place (same filesystem -> atomic); a reader
#                 never observes a half-written file
#
# Adapter seam (tests): the module sources the device jshn only when its
# functions are not already defined — a test pre-sources its own jshn
# adapter and puts a jsonfilter stub on PATH (see tooling/tests/run.sh).

command -v json_init >/dev/null 2>&1 || . /usr/share/libubox/jshn.sh

# Roots are env-overridable so the host-side tests can point them at a
# sandbox; on the device the defaults apply.
: "${NATMAP_STATUS_PRIVATE_DIR:=/var/run/natmap}"
: "${NATMAP_STATUS_PUBLIC_DIR:=/www/natmap}"

# _status_write <file> <mode> — write JSON text from stdin atomically.
_status_write() {
	local f="$1" m="$2" t
	t="$(mktemp "${f}.XXXXXX")" || return 1
	{ cat > "$t" && chmod "$m" "$t" && mv -f "$t" "$f"; } || { rm -f "$t"; return 1; }
}

# _status_name <name> <sid> — sanitize the public filename (see the frozen
# contract above); unsalvageable input falls back to the section id.
_status_name() {
	local n
	n="$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_' | sed 's/^[._-]*//')"
	printf '%s' "${n:-$2}"
}

# status_publish <sid> <comment> <name> <pid> <ip> <port> <ip4p>
#                <inner_port> <protocol> <inner_ip>
#
# Publish the section status for one mapping event: the private per-PID
# file and the public per-name file, from a single JSON build.
status_publish() {
	[ "$#" -eq 10 ] || return 1
	local sid="$1" comment="$2" name="$3" pid="$4" ip="$5" port="$6" ip4p="$7" inner_port="$8" protocol="$9" inner_ip="${10}"

	mkdir -p "$NATMAP_STATUS_PRIVATE_DIR" "$NATMAP_STATUS_PUBLIC_DIR" 2>/dev/null

	json_init
	json_add_string sid "$sid"
	json_add_string comment "$comment"
	json_add_string ip "$ip"
	json_add_int port "$port"
	json_add_string ip4p "$ip4p"
	json_add_int inner_port "$inner_port"
	json_add_string protocol "$protocol"
	json_add_string inner_ip "$inner_ip"
	json_dump | _status_write "$NATMAP_STATUS_PRIVATE_DIR/$pid.json" 600 || return 1

	name="$(_status_name "$name" "$sid")"
	json_add_string name "$name"
	json_add_string pid "$pid"
	json_dump | _status_write "$NATMAP_STATUS_PUBLIC_DIR/$name.json" 644
}

# status_clear [sid] — with <sid>, remove every status file of that section
# in both dirs, matched by the .sid field inside the JSON (the public
# filename may be name- or sid-based, so match content, not filenames; a
# respawned section can own several per-PID files — remove them all).
# Without <sid>, clear both dirs entirely.
status_clear() {
	local sid="${1:-}" dir f
	for dir in "$NATMAP_STATUS_PRIVATE_DIR" "$NATMAP_STATUS_PUBLIC_DIR"; do
		mkdir -p "$dir" 2>/dev/null
		if [ -n "$sid" ]; then
			for f in "$dir"/*.json; do
				[ -f "$f" ] || continue
				[ "$(jsonfilter -q -i "$f" -e '@.sid')" = "$sid" ] || continue
				rm -f "$f"
			done
		else
			find "$dir" -type f -print0 | xargs -0 rm -f --
		fi
	done
}
