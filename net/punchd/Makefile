# SPDX-License-Identifier: MIT
#
# punchd —— 路由器侧的 punch agent（home-ops docs/adr/0044：声明式 CGNAT 打洞）。
# 集群是唯一的声明源：punchd 每 15s 拉一份期望列表，每个 punch 起一个 natmap 子进程
# 把端口绑上去，再把 DNAT redirect 渲染进 fw4 的 ruleset-post 并回读校验，最后把
# 观测结果 POST 回去。路由器只是执行器 —— 没有 UCI section，改端口只改集群里的 CR。
#
# 源钉在 github.com/2017fighting/punch 的某一个 commit 上（不跟分支）。
#
# 现在钉的是 v0.2.2 那个 commit（47d6c08）：v0.2.2 = v0.2.1 + 「重启先停掉自己的 natmap
# 子进程」。之前 punchd 收到 SIGTERM 直接返回，子进程被 init 收养后继续占着 bindPort，新一版
# 根本绑不上（`[E] sock_connect src/hev-sock.c:60 Cannot assign requested address`），而 punch
# 一直显示 up —— 孤儿还在往同一个 report 路径写，把问题藏住了（2026-11-26 在自家路由器上
# 实测）。现在停机时 SIGTERM 每个子进程的进程组、等它退出、删掉它留下的 report；连 SIGTERM
# 都跑不到的那种（`kill -9`、procd 的 term_timeout）由下一次启动的扫描收尾 —— 按
# `-e <state_dir>/notify.sh` 认领，不误伤设备上别的 natmap。
#
# 上一版（v0.2.1）是「natmap 退出后重启它」；更早的 controller 侧改动跑在集群里，与路由器无关。
#
# 以后升到下一个 tag 同样做法：取 tag 指向的 40 位 sha，不要把这个变量写成 tag 名。
#
# 升级 = 改四处，一起改（apk 只按 PKG_VERSION-PKG_RELEASE 排序，所以日期没变时必须动
# release，否则已装设备看到的还是旧号）：
#   PKG_SOURCE_VERSION 40 位 sha —— 发布 tag 指向的那个 commit
#   PKG_VERSION        那个 commit 的日期（apk 只按它判升级）
#   PKG_RELEASE        同一日期内的重发计数（同日重钉 +1）
#   PKG_BUILD_VERSION  二进制里那份身份（<PKG_VERSION>-<sha7>，CI 的冒烟 grep 它）
#
# 刻意不写 PKG_MIRROR_HASH：git tarball 的 sha256 无法离线推算，写了就意味着每次
# 升级先跑一轮注定失败的 CI 把实际哈希读回来。副作用只有一个 —— 本包必须被
# build-plan.sh 认成 git 源，判据是 PKG_SOURCE_URL 以 .git 结尾。
include $(TOPDIR)/rules.mk

PKG_NAME:=punchd
# 钉点：2017fighting/punch v0.2.2 = 47d6c08（2026-11-27）
PKG_VERSION:=2026.11.27
# 1：v0.2.2 落在新的日期号上，release 从 1 重新开始。只有同一天重钉才需要 +1：
# v0.2.0 与 v0.2.1 都落在 2026.11.26 上，只靠 release 排开（apk 上验过
# 2026.11.26-r3 > 2026.11.26-r2）。2026.11.27-r1 > 2026.11.26-r3，apk 会照常升级。
PKG_RELEASE:=1

PKG_SOURCE:=$(PKG_NAME)-$(PKG_VERSION).tar.gz
PKG_SOURCE_SUBDIR:=$(PKG_NAME)-$(PKG_VERSION)
PKG_SOURCE_PROTO:=git
PKG_SOURCE_URL:=https://github.com/2017fighting/punch.git
PKG_SOURCE_VERSION:=47d6c08b6b5ceb8049b3ca051a629739d57b112a

# 上游从 v0.1.0 起带 MIT LICENSE（那一侧 docs/adr/0001-release-identity.md 记的是为何到
# 今天才补）。钉点必须落在一个含 LICENSE 的 commit 上，否则 PKG_LICENSE_FILES 指向的就是
# 个 tarball 里不存在的文件。
PKG_LICENSE:=MIT
PKG_LICENSE_FILES:=LICENSE
PKG_MAINTAINER:=2017fighting <2017fighting@users.noreply.github.com>

PKG_BUILD_DEPENDS:=golang/host
PKG_BUILD_PARALLEL:=1
PKG_BUILD_FLAGS:=no-mips16

PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)-$(PKG_VERSION)

# 只编 cmd/punchd。默认的 GO_PKG/... 会把 cmd/punch-controller（集群那一半，带
# client-go）也编出来 —— 它是容器镜像里的东西，路由器上不需要也不会被装，
# 而且 punchd 刻意保持不带 k8s 依赖。
GO_PKG:=github.com/2017fighting/punch
GO_PKG_BUILD_PKG:=github.com/2017fighting/punch/cmd/punchd

include $(INCLUDE_DIR)/package.mk
include $(TOPDIR)/feeds/packages/lang/golang/golang-package.mk

# v1：跑的是 J1900/N5105 这类老 x86_64 路由器。GOAMD64=v1 是 Go 支持的最低基线，
# v3 那点性能收益不值得换来一台机器 SIGILL。
ifeq ($(GO_ARCH),amd64)
  GO_AMD64:=v1
endif

# 版本号烘进二进制：main.version 由 golang-package.mk 的 GO_PKG_LDFLAGS_X 注入
# （-X main.version=…），所以设备上 `punchd -version` 打出来的就是这一串；PKG_BUILD_VERSION
# 就是 CI 从二进制里 grep 的那个值（tooling/build-plan.sh 的 compile 段）。
# 写成字面值而不是 $(PKG_VERSION)-…：plan 是 shell 侧 grep，展开不了的表达式它读不到；
# 代价是它就是第四个要跟着钉点走的常量（见文件头）。
PKG_BUILD_VERSION:=2026.11.27-47d6c08
GO_PKG_LDFLAGS_X:=main.version=$(PKG_BUILD_VERSION)

define Package/punchd
  SECTION:=net
  CATEGORY:=Network
  TITLE:=Declared-CGNAT punch agent (router side)
  URL:=https://github.com/2017fighting/punch
  # 依赖逐个对到代码行上（源码只在 cmd/punchd + internal/agent）：
  #
  # +natmap    punchd 唯一直接 exec 的外部程序：natmap.go 的 NewNatmap 先
  #            LookPath("natmap")、找不到才退回 /usr/bin/natmap，然后每个 punch 起一个
  #            `natmap -k 30 -s <stun> -h <http> -b <port> -4 -i <iface> -e <hook>` 子进程。
  #            natmap 是官方 openwrt/packages 的包（net/natmap；openwrt-25.12 里就是
  #            同一份 20260214 上游），而 packages feed 在本仓库 CI 里刻意不注册 ——
  #            所以这是运行时依赖：apk 的 Depends 里记着，设备 `apk add punchd` 时从
  #            自己的官方仓库装它，CI 不编（与 curl/bash 同一条机制）。
  #            以前这里写的是 +natmapt，即本仓库自带的一个更肥的变体（init/UCI + 5 个
  #            脚本子包）；punchd 只用二进制，多出来的东西没有消费者，已随 ADR 0002
  #            删除。注意 natmap 与 natmapt 抢同一批文件（/usr/bin/natmap、
  #            /etc/config/natmap）：仍装着 natmapt 的设备要先 `apk del natmapt`
  #            （ADR 0002 的迁移段）。
  #
  # +ca-bundle  cluster_url=https://punch.raenzo.com（files/punch.conf）：Go 的
  #            crypto/x509 只认 /etc/ssl/certs 里的系统根，而 ca-bundle 就是提供
  #            ca-certificates.crt 的那个包。缺了它第一条 https 请求就是
  #            "certificate signed by unknown authority"，punchd 每 tick 一条 unreachable。
  #
  # +firewall4  punchd 的两条硬需求都是 fw4 的：一是 nft(8)（nft.go 的 NewNftExec：
  #            LookPath("nft") → /usr/sbin/nft），二是 fw4 的 include 钩子
  #            /usr/share/nftables.d/ruleset-post/ —— agent.go 的 Preflight 直接读
  #            /etc/config/firewall 的 auto_includes，为 0 就拒绝启动。所以这里依
  #            赖 firewall4 而不是 nftables：后名只给二进制，前者才是「写进去的规则
  #            能活过一次 fw4 reload」的那东西（nft 本身由它的 nftables-json 带来）。
  #            代价：base feed 是注册着的，CI 会连带真编 nftables-json/libnftnl/
  #            libmnl/jansson + kmod-nft-* —— 换 apk 的 Depends: 说的是实话。
  DEPENDS:=+natmap +ca-bundle +firewall4
endef

define Package/punchd/description
  路由器侧的 punch agent（声明式 CGNAT 打洞；home-ops docs/adr/0044）：每 15s 从集群
  拉期望列表，每个 punch 起一个 natmap 子进程，把 DNAT redirect 渲染进 fw4 的
  ruleset-post 并回读校验，再把观测结果 POST 回去。声明只有集群一处，所以这里既没有
  UCI section 也没有 /etc/config/punch。

  **装完不自启**：bearer token 是设备本地的 /etc/punch/token（0600）—— 本包不带、
  也不该带任何 token，出厂镜像里当然也没有。运维放好 token（形状见
  /etc/punch/token.example）之后自己
  /etc/init.d/punchd enable && /etc/init.d/punchd start。
endef

define Package/punchd/conffiles
/etc/punch/punch.conf
endef

define Package/punchd/install
	$(call GoPackage/Package/Install/Bin,$(1))
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/punchd.init $(1)/etc/init.d/punchd
	# /etc/punch 是 0700：token 住这儿。包只定得住「新建」时的权限，此前手工 scp
	# 出来的老目录由 init 脚本每次启动幂等校准（它同时把已有 token 改成 0600）。
	$(INSTALL_DIR) $(1)/etc/punch
	$(INSTALL_CONF) ./files/punch.conf $(1)/etc/punch/punch.conf
	$(INSTALL_DATA) ./files/token.example $(1)/etc/punch/token.example
	chmod 0700 $(1)/etc/punch
endef

# /etc/punch 要活过 sysupgrade：conffiles 只保住 /etc/punch/punch.conf，token 是设备
# 本地文件（本包不带），不写进 sysupgrade.conf 就会在升级时连同凭据一起消失。
# sysupgrade.conf 自己由 base-files 保住，所以写一次就够；幂等，重装不会加第二行。
# 这里**不** enable 服务（token 还没放好，见上），只接线。
define Package/punchd/postinst
#!/bin/sh
[ -n "$$IPKG_INSTROOT" ] || {
	grep -qx '/etc/punch/' /etc/sysupgrade.conf 2>/dev/null ||
		echo '/etc/punch/' >>/etc/sysupgrade.conf
}
exit 0
endef

$(eval $(call GoBinPackage,punchd))
$(eval $(call BuildPackage,punchd))
