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

## mihomo 核

- **核（mihomo-alpha）** — 本 feed 自持包定义的 mihomo 二进制：官方
  `MetaCubeX/mihomo` Alpha 分支的**钉点**，装 `/usr/libexec/mihomo`（不建
  `/usr/bin` 符号链接），唯一消费者是 `mihomo-bare`。决策见 `docs/adr/0001`。
  _Avoid_: 内核、代理内核、fork 核

- **钉点（pin）** — `net/mihomo-alpha/Makefile` 里同源的三处常量：
  `PKG_SOURCE_VERSION`（40 位 sha）、`PKG_VERSION`（该提交的日期，apk 只按它
  判升级）、`PKG_BUILD_VERSION`（`alpha-<sha7>`，嵌进核里，CI 冒烟 grep 它）。
  升核 = 三处一起改；刻意不写 `PKG_MIRROR_HASH`（git tarball 的 sha256 无法
  离线推算），代价是 build plan 必须按 `PKG_SOURCE_URL` 以 `.git` 结尾来认
  git 源。_Avoid_: 版本、分支、频道

## mihomo-bare

- **裸核** — 路由器上只跑 mihomo 本体、不跑 nikki 包装层的那种部署形态：
  转面由核自己的 `tun.auto-route/auto-redirect` 建，配置原样来自
  `mihomo-headless-worker` 的 router 档案。术语与决策在那边：
  `CONTEXT.md` 的「裸核」、`docs/adr/0017`。

- **外壳包** — `net/mihomo-bare`：**纯脚本包**（无上游源码、无编译步骤），
  装 procd 守护、拉取校验脚本与 uci。依赖 `mihomo-alpha` 提供核 —— 核包同样
  住本仓库，但核是核、壳是壳：壳自己不编译任何东西。它只负责「把配置喂给核
  并盯着它」，**不**带 nft/ip rule/cgroup。

- **拉取校验** — `/usr/sbin/mihomo-bare-update` 的一次运行：curl 取订阅
  → `mihomo -t` 预检 → 字节比对 → 变了才原子替换并重启。预检失败丢弃
  新配置、继续跑上一份（坏配置不上线）。uci `enabled=0` 时直接退出：
  不拉取、不拉起 —— 否则 cron 会周期性地和并存的另一个转面（如回退期
  的 nikki）制造双核冲突（2026-11-13 早 08:30 事故）。

- **回程豁免** — `reply-bypass.nft` + `ip rule pref 8999 fwmark 0x99 → main`，
  由 init 装拆：tun.auto-route 的 ip rule（"not iif lo → 2022"）不看
  conntrack 方向，fw4 DNAT 过的入站连接（natmap 端口映射 / fullcone UDP /
  hairpin 反射）**回程包**也是 iif br-lan、dst=公网，与出站无从区分，会被
  吞进 tun —— 入站在 fw4 dstnat(100) 就已被 DNAT，mihomo 的链(101)对已建
  conntrack NAT 是 no-op，但回程走 main 的 default 被 suppress 后落到
  tun 表，mihomo 收到 mid-flow 包只能丢：洞打得开、数据进不来
  （2026-11-12 夜 natmap 全部失效的根因）。豁免用 `ct direction reply`
  打 mark，等价还原 nikki 每条链头部的 `ct direction reply return`
  （实测计数 3000 万+ 包）。mark 0x99 避开 tailscale 0x80000、natmap 0x42、
  sing-tun 0x2023/0x2024。对出站新流、tun 回包、本机收发均无行为变化。

- **失败开放（DNS）** — mihomo 停机时局域网仍能解析：dnsmasq 的
  `dns_redirect` 链保留作兜底，mihomo 的链优先级在它之前，活着时自然是它应答。

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
