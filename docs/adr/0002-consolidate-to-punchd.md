# Retire natmapt, stuntman and mihomo; punchd is the only package

`natmapt`, `luci-app-natmapt`, `stuntman`, `mihomo-bare` and `mihomo-alpha` are
deleted from this feed. Port mapping is now declared in the cluster and
executed by `punchd` (home-ops ADR 0044), which only needs the `natmap`
binary; the proxy runs the official mihomo package; the LuCI app existed to
drive natmapt, and `stuntman` existed only to serve that app's NAT-type test.
Keeping the old stack meant two mapping states, two owners of
`/usr/bin/natmap`, and build workarounds (boost, openssl, a second network
daemon) for code nothing ran any more.

## Considered Options

- **Keep natmapt for the manual/UCI path** (`/etc/init.d/natmap`, its status
  store, its five script splits): punchd's children cover the same mapping and
  the cluster is the single source of truth, so the second path would only be
  a stale manual override.
- **Keep `luci-app-natmapt` on top of the official `natmap`**: the app's status
  page reads the `/www/natmap/<name>.json` files natmapt's `status.sh`
  produced; the official package has no equivalent, so the page would be empty
  — and its NAT-type test would still need `stuntman-client`.
- **Keep building `mihomo-alpha`/`mihomo-bare`**: the router runs the official
  mihomo package now, so this feed would publish a duplicate binary with a
  pinned-commit build cost (`golang/host`) and no consumer.
- **Keep `CONFLICTS:=natmapt` on punchd**: apk 3 has no conflicts field
  (apk-package(5) knows only depends/provides), so it would not express the
  file clash on the device — a comment-free declaration with no effect.

## Consequences

- `punchd` depends on `+natmap` instead of `+natmapt`. The `packages` feed is
  still not registered in CI, so that is a runtime-only dep: the apk records
  it, and the device installs the official `natmap` (present in `openwrt-25.12`
  at the same upstream version) from its own repositories.
- `natmap` and `natmapt` own the same files (`/usr/bin/natmap`,
  `/etc/config/natmap`, `/etc/init.d/natmap`), so a device that still carries
  `natmapt` must remove it before punchd's dependency can land:
  `apk del natmapt luci-app-natmapt`, then `apk add punchd`. No package-level
  declaration can automate this (see above); the migration is operator work.
- The `/natmap/<name>.json` section-status contract is gone with natmapt: no
  publisher remains. Any external reader takes its state from the cluster
  (punch-controller's observed state) instead.
- The build plan shrinks to one package: `CORELIBS=golang` (openssl/boost left
  with stuntman), `COMPILE_ORDER=punchd`, one verify glob, and `feeds.conf`
  seeds `base` only (the luci feed was needed only by the LuCI app). The host
  tests lose the section-status-store suite and keep the build-plan suite.
