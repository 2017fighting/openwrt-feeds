#
# Copyright (C) 2026 2017fighting
#
# Lean LuCI app for the personal mosdns (cfst_pool/lpush) pipeline.
# Drop-in replacement for upstream sbwml/luci-app-mosdns: same package name,
# menu path, UCI namespace, and rpcd object. Treats /etc/mosdns/config_custom.yaml
# as the source of truth (in-browser editor) instead of generating it from UCI.
#

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-mosdns
PKG_VERSION:=1.0.0
PKG_RELEASE:=3
PKG_MAINTAINER:=2017fighting
PKG_LICENSE:=GPL-3.0

LUCI_TITLE:=LuCI Support for mosdns (cfst_pool/lpush pipeline)
LUCI_PKGARCH:=all
# Depends only on the mosdns binary (built by net/mosdns from the 2017fighting
# fork, which provides cfst_pool/lpush). No geo/adblock deps — those were the
# split machinery this app deliberately omits.
LUCI_DEPENDS:=+mosdns

define Package/$(PKG_NAME)/conffiles
/etc/mosdns/config_custom.yaml
/etc/mosdns/rule
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
