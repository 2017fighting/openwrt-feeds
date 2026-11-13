# SPDX-License-Identifier: MIT
#
# mihomo 官方 Alpha 线的 OpenWrt 包（docs/adr/0001）。源钉在 MetaCubeX/mihomo
# 的 Alpha 分支某一个 commit 上：既不是滚动的分支头，也不是任何个人 fork。
#
# 升级 = 三处同步改：
#   PKG_VERSION        钉点提交的日期（apk 只按它判升级）
#   PKG_SOURCE_VERSION 40 位 sha
#   PKG_BUILD_VERSION  alpha-<sha 前 7 位>，同时是内核里嵌的版本串，
#                      CI 的冒烟断言就 grep 它（tools/build-plan.sh compile）
#
# 故意不写 PKG_MIRROR_HASH：git tarball 的 sha256 无法离线推算，写了就意味着
# 每次升级先跑一轮注定失败的 CI 把实际哈希读回来。副作用只有一个 —— 本包必须
# 被 build-plan.sh 认成 git 源，判据是 PKG_SOURCE_URL 以 .git 结尾（见那边的
# _prefetch）。没有 md5/sha 校验，拉到的就是钉住的那个 commit。
include $(TOPDIR)/rules.mk

PKG_NAME:=mihomo-alpha
# 钉点：MetaCubeX/mihomo @ Alpha 12b81d4（2026-11-12）
PKG_VERSION:=2026.11.12
PKG_RELEASE:=1

PKG_SOURCE:=$(PKG_NAME)-$(PKG_VERSION).tar.gz
PKG_SOURCE_SUBDIR:=$(PKG_NAME)-$(PKG_VERSION)
PKG_SOURCE_PROTO:=git
PKG_SOURCE_URL:=https://github.com/MetaCubeX/mihomo.git
PKG_SOURCE_VERSION:=12b81d465a54f89919aae4bb832a4e89fd304e34

PKG_LICENSE:=GPL-3.0
PKG_LICENSE_FILES:=LICENSE
PKG_MAINTAINER:=2017fighting <2017fighting@users.noreply.github.com>

PKG_BUILD_DEPENDS:=golang/host
PKG_BUILD_PARALLEL:=1
PKG_BUILD_FLAGS:=no-mips16

PKG_BUILD_VERSION:=alpha-12b81d4
PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)-$(PKG_VERSION)
PKG_BUILD_TIME:=$(shell date -u -Iseconds)

GO_PKG:=github.com/metacubex/mihomo
GO_PKG_BUILD_PKG:=github.com/metacubex/mihomo
GO_PKG_LDFLAGS_X:=$(GO_PKG)/constant.Version=$(PKG_BUILD_VERSION) $(GO_PKG)/constant.BuildTime=$(PKG_BUILD_TIME)
GO_PKG_TAGS:=with_gvisor
GO_PKG_INSTALL_BIN_PATH:=/usr/libexec

include $(INCLUDE_DIR)/package.mk
include $(TOPDIR)/feeds/packages/lang/golang/golang-package.mk

# v1：与官方 release 的 amd64-compatible 产物同等，老 x86_64（J1900/N5105 之类）
# 不会 SIGILL。换成 v3 是纯性能取向的选择，路由器的收益不值得换来一台跑不动的机器。
ifeq ($(GO_ARCH),amd64)
  GO_AMD64:=v1
endif

define Package/mihomo-alpha
  SECTION:=net
  CATEGORY:=Network
  TITLE:=A rule based proxy in Go (upstream Alpha)
  URL:=https://github.com/MetaCubeX/mihomo
  # 二进制只装 /usr/libexec/mihomo：不声明 PROVIDES/CONFLICTS/ALTERNATIVES。
  # 本 feed 不再发布任何依赖虚拟包 mihomo 的包（nikki 栈已退场，见 docs/adr/0001），
  # 唯一的消费者 mihomo-bare 直接依赖本包并按这个路径起核。
  DEPENDS:=$(GO_ARCH_DEPENDS) +ca-bundle +ip-full +kmod-inet-diag +kmod-tun
endef

define Package/mihomo-alpha/description
  A rule based proxy in Go, built from the upstream Alpha branch of
  MetaCubeX/mihomo (commit-pinned; no downstream fork patches).
endef

define Package/mihomo-alpha/install
	$(call GoPackage/Package/Install/Bin,$(1))
endef

define Build/Prepare
	$(Build/Prepare/Default)
	$(RM) -r $(PKG_BUILD_DIR)/rules/logic_test
endef

$(eval $(call GoBinPackage,mihomo-alpha))
$(eval $(call BuildPackage,mihomo-alpha))
