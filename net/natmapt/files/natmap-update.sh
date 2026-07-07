#!/bin/bash
export ip="$1"
export port="$2"
export ip4p="$3"
export inner_port="$4"
export protocol="$5"
export inner_ip="$6"
shift 6

. /usr/share/libubox/jshn.sh
INITD='/etc/init.d/natmap'
STATUS_PATH='/var/run/natmap'
# Public status dir: uhttpd serves /www over HTTP, so /www/natmap/*.json is a
# query interface for other programs to read each section's live mapping.
PUBLIC_STATUS_PATH='/www/natmap'

# Add the status fields shared by the private and public files to the current
# json object.
build_status() {
	json_add_string sid "$SECTIONID"
	json_add_string comment "$COMMENT"
	json_add_string ip "$ip"
	json_add_int port "$port"
	json_add_string ip4p "$ip4p"
	json_add_int inner_port "$inner_port"
	json_add_string protocol "$protocol"
	json_add_string inner_ip "$inner_ip"
}

# Read JSON text from stdin and write <file> atomically: stage a temp file
# beside the target (same filesystem -> rename is atomic) so a reader never
# observes a half-written file.
_status_write() {
	local f="$1" t
	t="$(mktemp "${f}.XXXXXX")" || return 1
	cat > "$t" && mv -f "$t" "$f" || { rm -f "$t"; return 1; }
}

# fallloop <retry interval> <retry limit> <func> [args...]
fallloop() {
	local retry="$1"; shift
	local limit="$1"; shift
	local func="$1"; shift

	local error=1 count=0 && until [ $error = 0 -o $count -ge $limit ]; do
		$func "$@" && error=0 || error=$?
		let count++ && sleep $retry
	done
}

# keep dest_port(forward port) consistent with public port
if [ -n "$RWFW" -a "$($INITD info|jsonfilter -qe "@['$(basename $INITD)'].instances['$SECTIONID'].data.firewall[0].dest_port")" != "$port" ]; then
	export PUBPORT="$port" #PROCD_DEBUG=1
	$INITD start "$SECTIONID"
fi
# private status (keyed by PID; consumed by /etc/init.d/natmap)
(
	json_init
	build_status
	json_dump | _status_write "$STATUS_PATH/$PPID.json"
)

# public status, served by uhttpd as a query interface for other programs.
# Prefer a user-set STATUS_NAME (stable, readable URL) and fall back to the
# section id. Sanitize to a safe, non-hidden filename: '/' and other unsafe
# chars become '_' and leading [._-] are stripped — this blocks path traversal
# and keeps the file visible so the init script's glob-based cleanup matches it.
mkdir -p "$PUBLIC_STATUS_PATH" 2>/dev/null
_public_name="${STATUS_NAME:-$SECTIONID}"
_public_name="$(printf '%s' "$_public_name" | tr -c 'A-Za-z0-9._-' '_' | sed 's/^[._-]*//')"
[ -n "$_public_name" ] || _public_name="$SECTIONID"
(
	json_init
	build_status
	json_add_string name "$_public_name"
	json_add_string pid "$PPID"
	json_dump | _status_write "$PUBLIC_STATUS_PATH/$_public_name.json"
)

if [ -n "$REFRESH" ]; then
	json_init
	json_load "$REFRESH_PARAM"
	json_add_int port "$port"
	$REFRESH "$(json_dump)"
fi
if [ -n "$NOTIFY" ]; then
	_text="$(jsonfilter -qs "$NOTIFY_PARAM" -e '@["text"]')"
	[ -z "$_text" ] && _text="NATMap: ${COMMENT:+$COMMENT: }[${protocol^^}] $inner_ip:$inner_port -> $ip:$port" \
	|| _text="$(echo "$_text" | sed " \
		s|<comment>|$COMMENT|g; \
		s|<protocol>|$protocol|g; \
		s|<inner_ip>|$inner_ip|g; \
		s|<inner_port>|$inner_port|g; \
		s|<ip>|$ip|g; \
		s|<port>|$port|g")"
	json_init
	json_load "$NOTIFY_PARAM"
	json_add_string comment "$COMMENT"
	json_add_string text "$_text"
	fallloop 5m 4 $NOTIFY "$(json_dump)" &
fi
if [ -n "$DDNS" ]; then
	_hostype="$(jsonfilter -qs "$DDNS_PARAM" -e '@["hostype"]')"
	_svcparams="$(jsonfilter -qs "$DDNS_PARAM" -e '@["https_svcparams"]')"
	_svcparams="$(echo "$_svcparams" | sed -E "s,\s*(port=\d*|$), port=${port},")" # port
	[ "$_hostype" = A ]    && _svcparams="$(echo "$_svcparams" | sed -E "s|\b(ipv4hint=)\S*|\1${ip}|")" # ipv4hint
	[ "$_hostype" = AAAA ] && _svcparams="$(echo "$_svcparams" | sed -E "s|\b(ipv6hint=)\S*|\1${ip}|")" # ipv6hint
	json_init
	json_load "$DDNS_PARAM"
	json_add_string https_svcparams "$_svcparams"
	json_add_string ip "$ip"
	json_add_int port "$port"
	fallloop 5m 4 $DDNS "$(json_dump)" &
fi

[ -n "${CUSTOM_SCRIPT}" ] && {
	export -n CUSTOM_SCRIPT
	exec "${CUSTOM_SCRIPT}" "$ip" "$port" "$ip4p" "$inner_port" "$protocol" "$inner_ip" "$SECTIONID" "$COMMENT" "$@"
}
