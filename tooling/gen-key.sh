#!/usr/bin/env sh
# Generate the usign ed25519 keypair used to sign this feed's apk index
# (packages.adb -> packages.adb.sig), matching how official OpenWrt signs repos.
#
# Creates in the repo root:
#   key-build       PRIVATE key -> base64 into GitHub secret APK_SIGN_KEY, then delete.
#   key-build.pub   PUBLIC key  -> moved to keys/key-build.pub and committed.
#
# Requires `usign` on PATH, OR `docker` (builds usign in a throwaway container).
# If neither is available, run the 'keygen' workflow in GitHub Actions instead.
set -eu
cd "$(dirname "$0")/.."

if command -v usign >/dev/null 2>&1; then
  usign -G -s key-build -p key-build.pub -c "openwrt-feeds"
elif command -v docker >/dev/null 2>&1; then
  echo "usign not found; building it in a throwaway Docker container..." >&2
  docker run --rm -v "$PWD":/out alpine:3.20 sh -c '
    set -e
    apk add --no-cache build-base cmake git libsodium-dev >/dev/null
    cd /tmp && git clone --depth=1 https://github.com/openwrt/usign.git >/dev/null
    cd usign && cmake -B build >/dev/null 2>&1 && cmake --build build -j"$(nproc)" >/dev/null 2>&1
    ./build/usign -G -s /out/key-build -p /out/key-build.pub -c "openwrt-feeds"
  '
else
  echo "Need 'usign' or 'docker'. Or run the 'keygen' GitHub Actions workflow." >&2
  exit 1
fi

mkdir -p keys
mv key-build.pub keys/key-build.pub

echo
echo "Public key  -> keys/key-build.pub   (commit this)"
echo "Private key -> GitHub Actions secret APK_SIGN_KEY (base64 below); then delete key-build:"
echo
base64 key-build
echo
echo "After setting the secret:  rm key-build"
