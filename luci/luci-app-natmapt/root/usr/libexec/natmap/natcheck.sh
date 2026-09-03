#!/bin/sh
#
# Depends: coreutils-timeout
#
# Author: muink
# Github: https://github.com/muink/luci-app-natmap
#
# Args: <udp stun server:port> <tcp stun server:port> <localport>
# Prints PLAIN TEXT (two "UDP TEST:"/"TCP TEST:" sections). Consumed by the
# luci.natmap nattest rpcd method, which splits the sections and returns them
# as data — the view does the rendering. (It used to render colorized HTML
# here and have the JS inject it rawhtml; presentation now stays on the
# browser side of the seam.)
[ "$#" -ge 3 ] || exit 1
udpstun="$1" && shift
tcpstun="$1" && shift
port="$1" && shift

[ "$(echo "$udpstun" | sed 's|[A-Za-z0-9:.-]||g')" == "" ] || exit 1
[ "$(echo "$tcpstun" | sed 's|[A-Za-z0-9:.-]||g')" == "" ] || exit 1
[ "$(echo "$port" | sed 's|[0-9]||g')" == "" ] || exit 1

PROG="/usr/libexec/natmap/natmap-natest"
if [ -x "$(command -v stunclient)" ]; then ln -s "$(command -v stunclient)" "$PROG" 2>/dev/null; else exit 1; fi

udp_result="$(timeout 30 $PROG --protocol udp --mode full ${port:+--localport $port} ${udpstun%:*} ${udpstun#*:} 2>/dev/null)"
tcp_result="$(timeout 10 $PROG --protocol tcp --mode full ${port:+--localport $port} ${tcpstun%:*} ${tcpstun#*:} 2>/dev/null)"

cat <<- EOF
UDP TEST:
${udp_result:=Test timeout}

TCP TEST:
${tcp_result:=Test timeout}
EOF
