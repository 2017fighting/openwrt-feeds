# Domain glossary — openwrt-feeds

Terms with a stable meaning across this repo. Add a term when a conversation
names a concept that code, docs, and conversation should share.

## natmapt

- **Mapping event** — one pass of the natmap daemon through its `-e` hook
  (`/usr/lib/natmap/update.sh`): the outer ip/port (and IPv4-prefix for
  portforwarded IPv6) changed or was reconfirmed for a section. Every notify /
  client-refresh / DDNS reaction and every status publish hangs off one.

- **Section status** — the live mapping facts for one natmap section:
  `sid, comment, ip, port, ip4p, inner_port, protocol, inner_ip` (the public
  copy adds `name, pid`). Published as JSON at each mapping event.

- **Section status store** — the one module that writes, clears, and defines
  section status: `net/natmapt/files/status.sh`, installed as
  `/usr/lib/natmap/status.sh`. Interface: `status_publish` (10 positional
  args, identity first) and `status_clear [sid]`. Its header comment is the
  normative statement of the frozen on-disk contract (schema, filenames,
  perms, atomicity). Consumers: `/etc/init.d/natmap` (clear),
  `/usr/lib/natmap/update.sh` (publish), external readers via the public URL
  `/natmap/<name>.json` served by uhttpd.

## nikki 栈

- **三件套** — `mihomo-alpha`（源自 2017fighting/mihomo fork）+
  `nikki` + `luci-app-nikki`。本 feed 全量提供这三包，设备侧不再混用
  官方 nikki feed，`mihomo` 虚拟包因此只有单一提供者。

- **桥（nikki bridge）** — build plan 在 SDK `feeds.conf` 里写入的一行钉住
  commit 的 `src-git nikki`：指向 `2017fighting/OpenWrt-nikki`，三件套的
  Makefile 只在那边维护，本仓库不拷贝包目录。升级 = bump 桥上的 commit。

## CI

- **Build plan** — the derived description of what CI builds inside the
  OpenWrt SDK and how: source package names (from every Makefile dir under
  `net/` and `luci/`), compile order, tarball pre-fetch URLs (expanded from
  Make variables), the corelib workarounds (boost/openssl sparse checkouts,
  the `.config` seed) and the apk verification globs. The **build plan
  module** is `tooling/build-plan.sh`; `build-plan.sh plan` is its hermetic
  dry-run and its test surface (`tooling/tests/` asserts it against the
  Makefiles). The workflow supplies only the matrix (from `feeds.config`) and
  the two secret-touching steps (key install, `apk adbsign`) — secrets never
  enter the module. A **corelib** is a core library the SDK cannot build
  (boost, openssl), declared once in the module's static corelib table and
  pulled into the feed at CI time.
