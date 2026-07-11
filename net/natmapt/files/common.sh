#!/bin/bash
# Copyright (C) 2023 muink https://github.com/muink
#
# depends curl jsonfilter

CURL="$(command -v natmap-curl)"

# url_base <url> — strip trailing '/' so callers can safely append '/path'.
# Only trailing slashes are removed; the scheme's '//' is preserved, so
# `url_base https://x/qbt/` -> `https://x/qbt` -> `https://x/qbt/api/...`.
# POSIX-only (runs under busybox ash in the client scripts).
url_base() {
	local _u="$1"
	while [ "$_u" != "${_u%/}" ]; do _u="${_u%/}"; done
	printf '%s' "$_u"
}

# JSON_EXPORT <json>
JSON_EXPORT() {
	for k in $ALL_PARAMS; do
		jsonfilter -qs "$1" -e "$k=@['$k']"
	done
}

# INIT_GLOBAL_VAR <var1> [var2] [var3] ...
INIT_GLOBAL_VAR() {
	for _key in "$@"; do
		eval "$_key=''"
	done
}
