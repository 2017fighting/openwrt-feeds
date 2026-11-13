# Drop the nikki bridge; build mihomo-alpha from upstream Alpha here

The nikki stack (`mihomo-alpha` + `nikki` + `luci-app-nikki` + its zh-cn i18n
split) used to arrive through a commit-pinned `src-git` bridge to
`2017fighting/OpenWrt-nikki`. `mihomo-bare` replaced the nikki wrapper on the
router (ADR 0017 in `mihomo-headless-worker`), so the wrapper packages had no
consumer left — and the bridge's `mihomo-alpha` was built from a personal fork
(`2017fighting/mihomo` = upstream Alpha + `preferred-ip` + `heybox`) that had
drifted 83 commits behind. The bridge is gone: this feed owns
`net/mihomo-alpha/Makefile` and pins one commit of upstream
`MetaCubeX/mihomo`'s `Alpha` branch.

## Considered Options

- **Keep the bridge, point it at a third-party feed** (e.g.
  `morytyann/OpenWrt-mihomo`): the Makefile stays outside this repo, but every
  build then rides on someone else's packaging decisions and release cadence.
- **Follow the Alpha branch head** instead of a commit: never stale, but no
  build is reproducible, and both the embedded version assertion and any mirror
  hash lose their meaning.
- **Keep the fork** to retain `preferred-ip` + `heybox`: the router profile
  turned out to need neither — `preferred-ip` was retired in the worker,
  `heybox` is never emitted, and `disable-qtype-64/65` (ADR 0017's other
  fork-only worry) is an upstream nameserver URL-fragment parameter, not a
  patch.

## Consequences

- `mihomo-alpha` installs only `/usr/libexec/mihomo` — no `PROVIDES:=mihomo`,
  no `CONFLICTS`, `VARIANT` or `ALTERNATIVES`, because nothing in this feed
  depends on the virtual `mihomo` name any more. A device that still has
  `nikki` installed loses that provider, and any stored uci config naming
  `/usr/bin/mihomo` has to move: `/etc/config/mihomo-bare` is a conffile, so
  `90-mihomo-bare` rewrites that line on upgrade instead of relying on the
  package's default.
- No `PKG_MIRROR_HASH`: a git tarball's sha256 cannot be computed offline, so
  keeping it would cost one doomed CI run per bump. The price is paid in
  `tooling/build-plan.sh`, which must recognise git sources by
  `PKG_SOURCE_URL` ending in `.git` rather than by the mirror hash.
- Bumping is three edits in one file: `PKG_VERSION` (the pinned commit's date —
  apk only orders by it), `PKG_SOURCE_VERSION` (the 40-hex sha) and
  `PKG_BUILD_VERSION` (`alpha-<sha7>`, the string CI greps out of the built
  binary to prove the tarball is the pinned one).
