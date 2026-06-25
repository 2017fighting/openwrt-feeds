#
# Copyright (C) 2026 2017fighting
#
# This package builds mosdns from the fork at https://github.com/2017fighting/mosdns
# (GPL-3.0, upstream https://github.com/IrineSistiana/mosdns).
#
# mosdns is a pure-Go binary (CGO disabled), so it cross-compiles to a static
# linux/amd64 binary with a host Go toolchain. The OpenWrt SDK is used for
# packaging into a signed .apk only; its musl/gcc toolchain is not exercised.
#

include $(TOPDIR)/rules.mk

PKG_NAME:=mosdns
PKG_VERSION:=5.4.1
PKG_RELEASE:=2

# Source: GitHub source archive of the fork's pinned tag. PKG_HASH pins it.
# The archive extracts to mosdns-<version>, matching the default PKG_BUILD_DIR.
PKG_SOURCE:=mosdns-$(PKG_VERSION).tar.gz
PKG_SOURCE_URL:=https://github.com/2017fighting/mosdns/archive/refs/tags/v$(PKG_VERSION).tar.gz
PKG_HASH:=262cc4999d01b87997a35a4330b0363009145638a0d13c3b33f7a87b93d7ea7a

PKG_LICENSE:=GPL-3.0
PKG_LICENSE_FILES:=LICENSE
PKG_MAINTAINER:=2017fighting

# GOARCH for the Go cross-compile. Default amd64; overridden from the workflow
# matrix (arm64 for aarch64_generic, etc.) via `make ... MOSDNS_GOARCH=<goarch>`.
MOSDNS_GOARCH?=amd64
MOSDNS_GOVERSION:=$(PKG_VERSION)

include $(INCLUDE_DIR)/package.mk

define Package/mosdns
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=IP Addresses and Names
  TITLE:=mosdns - plugin-based DNS forwarder
  URL:=https://github.com/IrineSistiana/mosdns
  DEPENDS:=
  # Pure-Go static binary; PKGARCH auto-detects the SDK target arch
  # (x86_64 / aarch64_generic / ...), so the same Makefile is multi-arch.
endef

define Package/mosdns/description
  mosdns is a plugin-based DNS forwarder/diverter that can be flexibly
  configured to build custom DNS pipelines. Pure-Go static binary.
endef

# Build with the host Go toolchain (provided by actions/setup-go in CI; must be
# on PATH when this recipe runs). CGO disabled -> static binary, no musl needed.
define Build/Compile
	cd $(PKG_BUILD_DIR) && \
	GOOS=linux GOARCH=$(MOSDNS_GOARCH) CGO_ENABLED=0 GOFLAGS="-buildvcs=false -mod=readonly" \
	go build -trimpath -ldflags "-s -w -X main.version=$(MOSDNS_GOVERSION)" -o mosdns .
endef

define Package/mosdns/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/mosdns $(1)/usr/bin/mosdns

	$(INSTALL_DIR) $(1)/etc/mosdns
	$(INSTALL_CONF) ./files/config.yaml $(1)/etc/mosdns/config.yaml

	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/mosdns.uci $(1)/etc/config/mosdns

	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/mosdns.init $(1)/etc/init.d/mosdns

	$(INSTALL_DIR) $(1)/usr/share/mosdns
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/LICENSE $(1)/usr/share/mosdns/LICENSE
endef

define Package/mosdns/conffiles
/etc/config/mosdns
/etc/mosdns/config.yaml
endef

$(eval $(call BuildPackage,mosdns))
