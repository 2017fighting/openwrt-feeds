# SPDX-License-Identifier: MIT
#
# 纯脚本包：没有上游源码，也没有编译步骤 —— 装的是 mihomo 的**运行时外壳**
# （procd 守护 + 拉取校验 + 面板目录约定），核本身由 mihomo-alpha 提供。
# 它取代 nikki 的「包 + uci 模型 + nft 转面」三件套里不需要的那两层：
# 透明代理转面由 mihomo 自己的 tun.auto-route/auto-redirect 承担（docs/adr/0017
# 在 mihomo-headless-worker 侧），路由器上只剩「把配置喂给核并盯着它」。
include $(TOPDIR)/rules.mk

PKG_NAME:=mihomo-bare
PKG_VERSION:=0.1.0
PKG_RELEASE:=1
PKG_LICENSE:=MIT
PKG_MAINTAINER:=2017fighting <2017fighting@users.noreply.github.com>

include $(INCLUDE_DIR)/package.mk

define Package/mihomo-bare
  SECTION:=net
  CATEGORY:=Network
  TITLE:=Bare mihomo runtime for routers (no nikki wrapper)
  URL:=https://github.com/2017fighting/mihomo-headless-worker
  # 核就来自身边的 mihomo-alpha（同一个 fork，带 preferred-ip / heybox）。
  # 订阅用 curl 拉取；ca-bundle 供 DoH/wss 订阅的 TLS 校验。
  DEPENDS:=+mihomo-alpha +curl +ca-bundle
endef

define Package/mihomo-bare/description
  把 mihomo 当裸核跑：procd 守护、配置拉取 + 语法预检 + 原子替换、面板目录。
  不提供 nikki 的 nft/ip rule/cgroup 转面 —— 转面由核自己的 TUN 承担，
  配置内容完全由 mihomo-headless-worker 的 router 档案生成。
endef

define Package/mihomo-bare/conffiles
/etc/config/mihomo-bare
endef

define Package/mihomo-bare/install
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/mihomo-bare.config $(1)/etc/config/mihomo-bare
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/mihomo-bare.init $(1)/etc/init.d/mihomo-bare
	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_BIN) ./files/mihomo-bare-update $(1)/usr/sbin/mihomo-bare-update
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./files/90-mihomo-bare $(1)/etc/uci-defaults/90-mihomo-bare
endef

# cron 行由 uci-defaults 装、由 prerm 摘；不留在 /etc/crontabs/root 里当孤儿
define Package/mihomo-bare/prerm
#!/bin/sh
sed -i '/mihomo-bare/d' "$$IPKG_INSTROOT/etc/crontabs/root" 2>/dev/null
/etc/init.d/mihomo-bare stop 2>/dev/null
/etc/init.d/mihomo-bare disable 2>/dev/null
exit 0
endef

define Package/mihomo-bare/postinst
#!/bin/sh
[ -n "$$IPKG_INSTROOT" ] || {
	/etc/init.d/mihomo-bare enable
	/etc/init.d/network reload 2>/dev/null
}
exit 0
endef

$(eval $(call BuildPackage,mihomo-bare))
