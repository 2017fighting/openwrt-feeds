# openwrt-feeds

A self-built **OpenWrt source feed** whose binary packages are compiled with the
OpenWrt SDK in GitHub Actions and published as a **signed APK feed** to GitHub
Pages.

- **OpenWrt version:** 25.12.4 (APK package manager)
- **Architecture:** x86_64
- **Live binary feed:** <https://2017fighting.github.io/openwrt-feeds/25.12.4/x86_64/>
- **Packages:** `mosdns` (a plugin-based DNS forwarder; <https://github.com/IrineSistiana/mosdns>)

This repository is **both** the source feed (OpenWrt package `Makefile`s on
`main`) and the generator of the published binary feed.

## Install on a 25.12.4 x86_64 device

```sh
# 1. Trust this feed's signing key (apk EC public key; apk reads all of /etc/apk/keys/)
wget -O /etc/apk/keys/openwrt-feeds.pem \
  https://raw.githubusercontent.com/2017fighting/openwrt-feeds/main/keys/openwrt-feeds.pem

# 2. Add the repository (point at the directory; apk fetches <url>/packages.adb)
echo 'https://2017fighting.github.io/openwrt-feeds/25.12.4/x86_64' \
  >> /etc/apk/repositories

# 3. Install
apk update
apk add mosdns

# 4. Enable + start the service (procd)
/etc/init.d/mosdns enable
/etc/init.d/mosdns start
```

For a custom firmware image (ASU / imagebuilder), point the additional feed URL
**directly at the index**, e.g.
`https://2017fighting.github.io/openwrt-feeds/25.12.4/x86_64/packages.adb`.

> The default config (`/etc/mosdns/config.yaml`) forwards to Google DNS and
> listens on `127.0.0.1:53`. Edit it for your network and
> `/etc/init.d/mosdns restart`.

## Signing

Only the repository index (`packages.adb`) is signed — apk never signs
individual `.apk` files. The signature is an **openssl EC (prime256v1 / NIST
P-256)** signature embedded directly in `packages.adb` (there is no separate
`.sig` file), produced with `apk adbsign --sign-key` — exactly how official
OpenWrt signs its apk repos.

- Public key: [`keys/openwrt-feeds.pem`](keys/openwrt-feeds.pem)
  (`-----BEGIN PUBLIC KEY-----`) — install into `/etc/apk/keys/`.
- Private key (`private-key.pem`): stored only as the GitHub Actions secret
  `APK_SIGN_KEY`; never committed. The key is permanent — rotating it is a
  breaking change (every installed device must add the new public key).

## How it is built

`.github/workflows/build.yml` runs on every push to `main` (and via manual
dispatch):

1. Download + extract the matching OpenWrt SDK.
2. Register this repo as a feed (`src-link`) inside the SDK.
3. Compile each package (`make package/<feed>/<pkg>/compile`).
4. Generate + sign the index (`make package/index` → `packages.adb` + `.sig`).
5. Publish the whole site to GitHub Pages (`actions/deploy-pages`).

## Repository layout

```
net/mosdns/          # the mosdns package (Makefile + default config + init script)
keys/                # apk EC public signing key (committed; private key is a CI secret)
tooling/             # keygen helper (tooling/gen-key.sh)
feeds.config         # supported feeds (version x arch) — drives the build matrix
.github/workflows/   # CI: build, sign, publish
```

## Adding a package

Drop a new `<category>/<pkg>/Makefile` (standard OpenWrt package definition) at
the repo root and push. The build picks it up automatically.

## Adding a version or architecture

Add an entry to [`feeds.config`](feeds.config) (and, for now, the inlined matrix
in `build.yml`). The SDK URL and Go `GOARCH` are derived from the entry.

## License

Package sources retain their upstream licenses. `mosdns` is **GPL-3.0**
(<https://github.com/IrineSistiana/mosdns>); its `LICENSE` is shipped inside the
package at `/usr/share/mosdns/LICENSE`.
