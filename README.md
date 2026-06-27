# openwrt-feeds

A self-built **OpenWrt source feed** whose binary packages are compiled with the
OpenWrt SDK in GitHub Actions and published as a **signed APK feed** to GitHub
Pages.

- **OpenWrt version:** 25.12.4 (APK package manager)
- **Architectures:** `x86_64`, `aarch64_generic`
- **Live binary feed:** <https://2017fighting.github.io/openwrt-feeds/25.12.4/>
- **Packages:** `mosdns` + `luci-app-mosdns` (plugin-based DNS forwarder + LuCI app; <https://github.com/IrineSistiana/mosdns>), `natmapt` + `luci-app-natmapt` (TCP/UDP port mapping for full-cone NAT + LuCI app; <https://github.com/heiher/natmap>), and `stuntman-client` (STUN client used by natmapt's NAT-type test; <https://github.com/jselbie/stunserver>)
- **Quick install:** `sh -c "$(wget -O- https://2017fighting.github.io/openwrt-feeds/feed.sh)"`

This repository is **both** the source feed (OpenWrt package `Makefile`s on
`main`) and the generator of the published binary feed.

## Quick install

On the device, run the one-shot installer — it detects the arch and release,
installs the signing key, registers the feed, and runs `apk update`:

```sh
sh -c "$(wget -O- https://2017fighting.github.io/openwrt-feeds/feed.sh)"
```

Then install packages and enable the service:

```sh
# mosdns (plugin-based DNS forwarder)
apk add mosdns luci-app-mosdns
/etc/init.d/mosdns enable && /etc/init.d/mosdns start

# natmapt (TCP/UDP port mapping for full-cone NAT) + LuCI app
apk add natmapt luci-app-natmapt
/etc/init.d/natmap enable && /etc/init.d/natmap start
```

`apk add natmapt` auto-installs its runtime deps (`curl`, `jsonfilter`, `bash`),
and `apk add luci-app-natmapt` auto-installs `coreutils-timeout` and
`stuntman-client` (the STUN client for the NAT-type test) — resolved from the
device's own repos plus this feed. Default OpenWrt ships busybox `ash`/`wget`
rather than `bash`/`curl`, so those are pulled on install.

Prefer to read it first? See [`feed.sh`](feed.sh), mirrored on [the Pages
site](https://2017fighting.github.io/openwrt-feeds/feed.sh). It is apk-only and
refuses opkg-only releases.

## Manual install

The steps below are what `feed.sh` automates, in case you prefer to do them by
hand. Swap `x86_64` for `aarch64_generic` on armsr/armv8 devices.

```sh
# 1. Trust this feed's signing key (apk EC public key; apk reads all of /etc/apk/keys/)
wget -O /etc/apk/keys/2017fighting.pem \
  https://raw.githubusercontent.com/2017fighting/openwrt-feeds/main/keys/2017fighting.pem

# 2. Add the repository (point at the SIGNED INDEX; apk reads a *.adb URL
#    directly — the bare directory makes it probe legacy APKINDEX.tar.gz and fail)
echo 'https://2017fighting.github.io/openwrt-feeds/25.12.4/x86_64/packages.adb' \
  >> /etc/apk/repositories

# 3. Install
apk update
apk add mosdns

# 4. Enable + start the service (procd)
/etc/init.d/mosdns enable
/etc/init.d/mosdns start
```

Always point the feed at the **signed index file** (`packages.adb`), not the
directory — the bare directory makes apk probe the legacy `<arch>/APKINDEX.tar.gz`
and warn (`unexpected end of file`). The same `packages.adb` URL is what a custom
firmware image (ASU / imagebuilder) consumes as an additional feed.

> The default config (`/etc/mosdns/config.yaml`) runs the cfst_pool/lpush
> Cloudflare-speedtest pipeline: it listens on `:1053` (UDP+TCP), forwards via
> mihomo (`127.0.0.1:2053`) with a `223.5.5.5` fallback, and rewrites Cloudflare
> response IPs with the fastest probed IPs. Edit it (or use the LuCI app) and
> `/etc/init.d/mosdns restart`.

## Signing

Only the repository index (`packages.adb`) is signed — apk never signs
individual `.apk` files. The signature is an **openssl EC (prime256v1 / NIST
P-256)** signature embedded directly in `packages.adb` (there is no separate
`.sig` file), produced with `apk adbsign --sign-key` — exactly how official
OpenWrt signs its apk repos.

- Public key: [`keys/2017fighting.pem`](keys/2017fighting.pem)
  (`-----BEGIN PUBLIC KEY-----`) — install into `/etc/apk/keys/`.
- Private key (`private-key.pem`): stored only as the GitHub Actions secret
  `APK_SIGN_KEY`; never committed. The key is permanent — rotating it is a
  breaking change (every installed device must add the new public key).

## How it is built

`.github/workflows/build.yml` runs on every push to `main` (and via manual
dispatch):

1. Download + extract the matching OpenWrt SDK.
2. Register this repo as a feed (`src-link`) inside the SDK; register `luci`
   only, not `packages` (see [`CLAUDE.md`](CLAUDE.md) for why).
3. Pull the core libs `stuntman-client` needs (`boost`, `openssl`) into this
   feed at CI time, then compile each package
   (`make package/feeds/<feed>/<pkg>/compile`).
4. Generate + sign the index (`make package/index` → `packages.adb`, signed
   in-place by `apk adbsign` — no separate `.sig`).
5. Publish the whole site to GitHub Pages (`actions/deploy-pages`).

## Repository layout

```
net/mosdns/            # the mosdns package (Makefile + default config + init script)
net/natmapt/           # natmapt — TCP/UDP port mapping for full-cone NAT (binary + scripts + init)
net/stuntman/          # stuntman-client — STUN client (stunclient) for natmapt's NAT-type test
luci/luci-app-mosdns/  # the mosdns LuCI app (Makefile + htdocs/root)
luci/luci-app-natmapt/ # the natmapt LuCI app (htdocs + rpcd + translations)
keys/                 # apk EC public signing key (committed; private key is a CI secret)
tooling/              # keygen + Pages index helpers (gen-key.sh, make-index.sh)
feed.sh               # one-shot on-device installer (key + feed + apk update)
feeds.config          # supported feeds (version x arch) — drives the build matrix
.github/workflows/    # CI: build, sign, publish
```

## Adding a package

Drop a new `<category>/<pkg>/Makefile` (standard OpenWrt package definition) at
the repo root, then wire it into `.github/workflows/build.yml`: add it to the
`feeds install` line and a `make package/feeds/$FEED_NAME/<pkg>/compile` step.
It is **not** automatic — the SDK ships no core package sources and only builds
feed packages, so anything needing a core lib (openssl/boost/…) or a standard
runtime dep needs the patterns described in [`CLAUDE.md`](CLAUDE.md) (runtime-only
deps via the unregistered `packages` feed; core libs pulled into this feed at
CI time).

## Adding a version or architecture

Add an entry to [`feeds.config`](feeds.config) (and, for now, the inlined matrix
in `build.yml`). The SDK URL and Go `GOARCH` are derived from the entry.

## License

Package sources retain their upstream licenses. `mosdns` is **GPL-3.0**
(<https://github.com/IrineSistiana/mosdns>); its `LICENSE` is shipped inside the
package at `/usr/share/mosdns/LICENSE`. `natmapt` is **MIT** and
`luci-app-natmapt` is **Apache-2.0** (<https://github.com/heiher/natmap>,
<https://github.com/muink/luci-app-natmapt>). `stuntman` is **Apache-2.0**
(<https://github.com/jselbie/stunserver>). This feed also ships `libopenssl`
(**Apache-2.0**) and `boost` (**BSL-1.0**) — pulled in at CI time as
stuntman-client's build/runtime deps (redundant with the device's core, same
versions).
