#!/bin/sh

# openwrt-feeds — one-shot installer for the signed apk feed.
#
# Detects the running image's arch + release, installs this feed's apk signing
# key, registers the repository, and runs `apk update`. Modeled on the nikki
# project's feed.sh, but apk-only (OpenWrt 25.12.x): this feed is published
# solely as apk packages, so there is no opkg path.
#
# Run on the device:
#   sh -c "$(wget -O- https://2017fighting.github.io/openwrt-feeds/feed.sh)"
# …or download and read it first:
#   wget -O feed.sh https://2017fighting.github.io/openwrt-feeds/feed.sh && sh feed.sh

# --- 1. This is an apk feed; refuse opkg-only releases -----------------------
if [ ! -x /usr/bin/apk ]; then
	echo "openwrt-feeds is an apk feed and needs OpenWrt 24.10+/25.12 (apk)."
	echo "opkg-only releases (e.g. 23.05) are not supported."
	exit 1
fi

# --- 2. Read the running image's release + arch -------------------------------
. /etc/openwrt_release
arch="$DISTRIB_ARCH"

# Published feed path segment. MUST stay in sync with feeds.config's
# openwrt_version (the site is laid out as <version>/<arch>/). Add a new
# case when a new OpenWrt version is published.
case "$DISTRIB_RELEASE" in
	*"25.12"*)
		version="25.12.4"
		;;
	*)
		echo "unsupported release: $DISTRIB_RELEASE (only OpenWrt 25.12.x is published)"
		exit 1
		;;
esac

# Only the arches in feeds.config are built; fail early with a clear message
# instead of a cryptic apk "no index" error on update.
case "$arch" in
	x86_64|aarch64_generic) ;;
	*)
		echo "unsupported arch: $arch (published: x86_64, aarch64_generic)"
		exit 1
		;;
esac

repository_url="https://2017fighting.github.io/openwrt-feeds"
key_url="$repository_url/keys/2017fighting.pem"
feed_url="$repository_url/$version/$arch"
# Unique to this feed; used to dedup a prior entry on re-runs.
marker="2017fighting.github.io/openwrt-feeds"

# --- 3. Add the signing key --------------------------------------------------
echo "add key"
wget -O /etc/apk/keys/2017fighting.pem "$key_url"

# --- 4. Register the feed (idempotent) ---------------------------------------
echo "add feed"
# Community feeds go in repositories.d/customfeeds.list (apk 3.x on OpenWrt
# sources this). Point at the directory — apk fetches <url>/packages.adb.
list=/etc/apk/repositories.d/customfeeds.list
mkdir -p /etc/apk/repositories.d
touch "$list"
# Drop any prior entry for this feed — from a previous run, or the manual
# /etc/apk/repositories line shown in the README — so we never leave a duplicate.
for f in /etc/apk/repositories "$list"; do
	[ -f "$f" ] || continue
	grep -q "$marker" "$f" && sed -i "\#$marker#d" "$f"
done
echo "$feed_url" >> "$list"

# --- 5. Update ---------------------------------------------------------------
echo "update feeds"
apk update

echo "success"
echo "now install:  apk add mosdns luci-app-mosdns"
