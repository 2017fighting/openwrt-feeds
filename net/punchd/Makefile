# SPDX-License-Identifier: MIT
#
# punchd —— 路由器侧的 punch agent（home-ops docs/adr/0044：声明式 CGNAT 打洞）。
# 集群是唯一的声明源：punchd 每 15s 拉一份期望列表，每个 punch 起一个 natmap 子进程
# 把端口绑上去，再把 DNAT redirect 渲染进 fw4 的 ruleset-post 并回读校验，最后把
# 观测结果 POST 回去。路由器只是执行器 —— 没有 UCI section，改端口只改集群里的 CR。
#
# 源钉在本仓库自己的 github.com/2017fighting/punch 的某一个 commit 上（不跟分支）。
# 2e56c87 是带上「首启自动建 ruleset-post 目录」那个修复的提交：出厂镜像上那个目录
# 并不存在，钉在这个提交之前，第一台新设备的第一条 tick 就写不进 include。
#
# 升级 = 改两处：
#   PKG_VERSION        钉点提交的日期（2026-11-26；apk 只按它判升级）
#   PKG_SOURCE_VERSION 40 位 sha
#
# 和 mihomo-alpha 一样故意不写 PKG_MIRROR_HASH：git tarball 的 sha256 无法离线推算，
# 写了就意味着每次升级先跑一轮注定失败的 CI 把实际哈希读回来。副作用只有一个 ——
# 本包必须被 build-plan.sh 认成 git 源，判据是 PKG_SOURCE_URL 以 .git 结尾。
include $(TOPDIR)/rules.mk

PKG_NAME:=punchd
# 钉点：2017fighting/punch @ main 2e56c87（2026-11-26）
PKG_VERSION:=2026.11.26
PKG_RELEASE:=1

PKG_SOURCE:=$(PKG_NAME)-$(PKG_VERSION).tar.gz
PKG_SOURCE_SUBDIR:=$(PKG_NAME)-$(PKG_VERSION)
PKG_SOURCE_PROTO:=git
PKG_SOURCE_URL:=https://github.com/2017fighting/punch.git
PKG_SOURCE_VERSION:=2e56c87328efbde9de0aa5149a26b2e496eb5f03

# 上游仓库还没有 LICENSE 文件 —— 这里不替它声称一份（PKG_LICENSE 只是元数据，
# 缺了不影响构建）；那边补上 LICENSE 之后，一行加回来即可。
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

# v1：与 mihomo-alpha 同一条理由 —— 跑的是同一批 x86_64 路由器（J1900/N5105 之类），
# 换 v3 换来的那点性能不值得让一台老机器 SIGILL。
ifeq ($(GO_ARCH),amd64)
  GO_AMD64:=v1
endif

# 没有 PKG_BUILD_VERSION：punchd 里没有可 -X 注入的版本变量（-buildvcs=false），
# 所以不像 mihomo-alpha 那样嵌一个 alpha-<sha7> 给 CI grep。CI 的冒烟改为认
# agent 自己的特征串（fw4 include 路径 /usr/share/nftables.d/ruleset-post），
# 见 tooling/build-plan.sh 的 compile。
define Package/punchd
  SECTION:=net
  CATEGORY:=Network
  TITLE:=Declared-CGNAT punch agent (router side)
  URL:=https://github.com/2017fighting/punch
  # 依赖逐个对到代码行上（源码只在 cmd/punchd + internal/agent）：
  #
  # +natmapt   punchd 唯一直接 exec 的外部程序：natmap.go 的 NewNatmap 先
  #            LookPath("natmap")、找不到才退回 /usr/bin/natmap，然后每个 punch 起一个
  #            `natmap -k 30 -s <stun> -h <http> -b <port> -4 -i <iface> -e <hook>` 子进程。
  #            这个包就在本 feed 里，所以是真依赖（真装、真升级），不是运行时兜底。
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
  #            libmnl/jansson + kmod-nft-*，与 mihomo-alpha 的 +ip-full/+kmod-tun
  #            同类 —— 换 apk 的 Depends: 说的是实话。
  DEPENDS:=+natmapt +ca-bundle +firewall4
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
