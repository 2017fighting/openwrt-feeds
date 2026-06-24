#!/usr/bin/env sh
# Generate the openssl EC (prime256v1 / NIST P-256) keypair used to sign this
# feed's apk index. This matches how official OpenWrt signs its apk repos:
#
#   private-key.pem        PRIVATE (-----BEGIN EC PRIVATE KEY-----)
#                          -> base64 into GitHub secret APK_SIGN_KEY, then delete.
#   keys/openwrt-feeds.pem PUBLIC  (-----BEGIN PUBLIC KEY-----)
#                          -> committed; devices install it into /etc/apk/keys/.
#
# The index is signed in CI with:  apk adbsign --sign-key private-key.pem packages.adb
# (the signature is embedded in packages.adb; there is no separate .sig file).
#
# Requires only `openssl` (libopenssl on macOS, openssl on Linux). No usign.
# Alternatively, run the 'keygen' workflow in GitHub Actions.
set -eu
cd "$(dirname "$0")/.."

command -v openssl >/dev/null 2>&1 || { echo "Need 'openssl' on PATH." >&2; exit 1; }

# Rotating the signing key is a breaking change for every installed device.
# Refuse to clobber an existing public key unless FORCE=1 is set.
if [ -f keys/openwrt-feeds.pem ] && [ "${FORCE:-0}" != "1" ]; then
  echo "::error:: keys/openwrt-feeds.pem already exists." >&2
  echo "   Reusing it would NOT change the key. To generate a NEW key (rotation," >&2
  echo "   breaking change), delete it first or re-run with:  FORCE=1 sh tooling/gen-key.sh" >&2
  exit 1
fi

# OpenWrt package/Makefile uses exactly these openssl commands:
#   openssl ecparam -name prime256v1 -genkey -noout   (private)
#   openssl ec -in <priv> -pubout                      (public)
openssl ecparam -name prime256v1 -genkey -noout -out private-key.pem
mkdir -p keys
openssl ec -in private-key.pem -pubout -out keys/openwrt-feeds.pem

# Sanity: the public key must be a PEM SubjectPublicKeyInfo block.
head -n1 keys/openwrt-feeds.pem | grep -q '^-----BEGIN PUBLIC KEY-----' \
  || { echo "::error:: generated public key is not a -----BEGIN PUBLIC KEY----- PEM" >&2; exit 1; }

echo
echo "Public key  -> keys/openwrt-feeds.pem   (commit this; devices put it in /etc/apk/keys/)"
echo "Private key -> GitHub Actions secret APK_SIGN_KEY (base64 below); then delete private-key.pem:"
echo
base64 < private-key.pem | tr -d '\n'
echo
echo
echo "After setting the secret:  rm private-key.pem"
