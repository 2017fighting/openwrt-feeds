# Domain glossary — openwrt-feeds

Terms with a stable meaning across this repo. Add a term when a conversation
names a concept that code, docs, and conversation should share.

## punchd

- **punchd** — the router-side punch agent (`net/punchd/`, this feed's only
  package; source = a commit-pinned `2017fighting/punch`): the cluster is the
  only declaration source, it pulls the desired list every 15s, runs one
  `natmap` child per punch, renders the DNAT into fw4's `ruleset-post` and
  reads it back to verify. It does **not** enable itself on install — the token
  is device-local (`/etc/punch/token`, never packaged), so the operator places
  it and enables the service.
  _Avoid_: punch 客户端、punch 容器、punch 插件

- **natmap** — the upstream binary punchd runs (one child per punch), packaged
  by `openwrt/packages`, not by this feed: it is declared as a runtime
  dependency and the device installs it from its own repositories.
  _Avoid_: natmapt (the retired in-feed variant, `docs/adr/0002`)

- **钉点（pin）** — a commit-pinned git source: `PKG_SOURCE_VERSION` (40-hex
  sha) plus `PKG_VERSION` (that commit's date — apk orders by it only), and,
  where the built binary carries one, `PKG_BUILD_VERSION` (`<label>-<sha7>`,
  which CI greps out of the binary). Deliberately no `PKG_MIRROR_HASH`: a git
  tarball's sha256 cannot be computed offline, so keeping one would cost a
  doomed CI run per bump — the cost is that the build plan must recognise git
  sources by `PKG_SOURCE_URL` ending in `.git`. Bumping a pin changes every
  constant together.
  _Avoid_: 版本、分支、频道

## CI

- **Build plan** — the derived description of what CI builds inside the
  OpenWrt SDK and how: source package names (from every Makefile dir under
  `net/`), compile order, tarball pre-fetch URLs (expanded from Make
  variables), the corelib workarounds (the golang sparse checkout, the
  `.config` seed) and the apk verification globs. The **build plan module** is
  `tooling/build-plan.sh`; `build-plan.sh plan` is its hermetic dry-run and its
  test surface (`tooling/tests/` asserts it against the Makefiles). The
  workflow supplies only the matrix (from `feeds.config`) and the two
  secret-touching steps (key install, `apk adbsign`) — secrets never enter the
  module.

- **Corelib** — a core library the SDK cannot build (today only `golang`,
  borrowed for punchd's `golang/host` and its hard include), declared once in
  the module's static corelib table and pulled into this feed at CI time.
