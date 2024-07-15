# Makefile for OpenWrt
#
# Copyright (C) 2007-2015 OpenWrt.org
#
# This is free software, licensed under the GNU General Public License v2.
# See /LICENSE for more information.
#

TOPDIR:=${CURDIR}
LC_ALL:=C
LANG:=C
export TOPDIR LC_ALL LANG
export OPENWRT_VERBOSE=s
all: help

include $(TOPDIR)/include/host.mk

ifneq ($(OPENWRT_BUILD),1)
  override OPENWRT_BUILD=1
  export OPENWRT_BUILD
endif

include rules.mk
include $(INCLUDE_DIR)/debug.mk
include $(INCLUDE_DIR)/depends.mk

include $(INCLUDE_DIR)/version.mk
export REVISION

define Helptext
Available Commands:
	help:	This help text
	info:	Show a list of available target profiles
	clean:	Remove images and temporary build files
	image:	Build an image (see below for more information).

Building images:
	By default 'make image' will create an image with the default
	target profile and package set. You can use the following parameters
	to change that:

	make image PROFILE="<profilename>" # override the default target profile
	make image PACKAGES="<pkg1> [<pkg2> [<pkg3> ...]]" # include extra packages
	make image FILES="<path>" # include extra files from <path>
	make image BIN_DIR="<path>" # alternative output directory for the images
	make image EXTRA_IMAGE_NAME="<string>" # Add this to the output image filename (sanitized)
endef
$(eval $(call shexport,Helptext))

help: FORCE
	echo "$$$(call shvar,Helptext)"


# override variables from rules.mk
PACKAGE_DIR:=$(TOPDIR)/packages
LISTS_DIR:=$(subst $(space),/,$(patsubst %,..,$(subst /,$(space),$(TARGET_DIR))))$(DL_DIR)
OPKG:= \
  IPKG_NO_SCRIPT=1 \
  IPKG_INSTROOT="$(TARGET_DIR)" \
  $(STAGING_DIR_HOST)/bin/opkg \
	-f $(TOPDIR)/repositories.conf \
	--force-depends \
	--force-overwrite \
	--force-postinstall \
	--cache $(DL_DIR) \
	--lists-dir $(LISTS_DIR) \
	--offline-root $(TARGET_DIR) \
	--add-dest root:/ \
	--add-arch all:100 \
	--add-arch $(ARCH_PACKAGES):200

include $(INCLUDE_DIR)/target.mk
-include .profiles.mk

USER_PROFILE ?= $(firstword $(PROFILE_NAMES))
PROFILE_LIST = $(foreach p,$(PROFILE_NAMES), \
	echo '$(patsubst DEVICE_%,%,$(p)):'; $(if $($(p)_NAME),echo '    $(subst ','"'"',$($(p)_NAME))'; ) echo '    Packages: $($(p)_PACKAGES)'; \
)

.profiles.mk: .targetinfo
	@$(SCRIPT_DIR)/target-metadata.pl profile_mk $< '$(BOARD)$(if $(SUBTARGET),/$(SUBTARGET))' > $@

staging_dir/host/.prereq-build: include/prereq-build.mk
	mkdir -p tmp
	rm -f tmp/.host.mk
	@$(_SINGLE)$(NO_TRACE_MAKE) -j1 -r -s -f $(TOPDIR)/include/prereq-build.mk prereq 2>/dev/null || { \
		echo "Prerequisite check failed. Use FORCE=1 to override."; \
		false; \
	}
  ifneq ($(realpath $(TOPDIR)/include/prepare.mk),)
	@$(_SINGLE)$(NO_TRACE_MAKE) -j1 -r -s -f $(TOPDIR)/include/prepare.mk prepare 2>/dev/null || { \
		echo "Preparation failed."; \
		false; \
	}
  endif
	touch $@

_call_info: FORCE
	echo 'Current Target: "$(BOARD)$(if $(SUBTARGET), ($(BOARDNAME)))"'
	echo 'Default Packages: $(DEFAULT_PACKAGES)'
	echo 'Available Profiles:'
	echo; $(PROFILE_LIST)

BUILD_PACKAGES:=$(USER_PACKAGES) $(sort $(DEFAULT_PACKAGES) $($(USER_PROFILE)_PACKAGES) kernel)
# "-pkgname" in the package list means remove "pkgname" from the package list
BUILD_PACKAGES:=$(filter-out $(filter -%,$(BUILD_PACKAGES)) $(patsubst -%,%,$(filter -%,$(BUILD_PACKAGES))),$(BUILD_PACKAGES))
PACKAGES:=

_call_image: staging_dir/host/.prereq-build
	echo 'Building images for $(BOARD)$(if $($(USER_PROFILE)_NAME), - $($(USER_PROFILE)_NAME))'
	echo 'Packages: $(BUILD_PACKAGES)'
	echo
	rm -rf $(TARGET_DIR)
	mkdir -p $(TARGET_DIR) $(BIN_DIR) $(TMP_DIR) $(DL_DIR)
	$(MAKE) package_reload
	$(MAKE) package_install
ifneq ($(USER_FILES),)
	$(MAKE) copy_files
endif
	$(MAKE) -s package_postinst
	$(MAKE) -s build_image
	$(MAKE) -s checksum

package_index: FORCE
	@echo >&2
	@echo Building package index... >&2
	@mkdir -p $(TMP_DIR) $(TARGET_DIR)/tmp
	(cd $(PACKAGE_DIR); $(SCRIPT_DIR)/ipkg-make-index.sh . > Packages && \
		gzip -9nc Packages > Packages.gz \
	) >/dev/null 2>/dev/null
	$(OPKG) update >&2 || true

package_reload:
	if [ ! -f "$(PACKAGE_DIR)/Packages" ] || [ ! -f "$(PACKAGE_DIR)/Packages.gz" ] || [ "`find $(PACKAGE_DIR) -cnewer $(PACKAGE_DIR)/Packages.gz`" ]; then \
		echo "Package list missing or not up-to-date, generating it." >&2 ;\
		$(MAKE) package_index; \
	else \
		mkdir -p $(TARGET_DIR)/tmp; \
		$(OPKG) update >&2 || true; \
	fi

package_list: FORCE
	@$(MAKE) -s package_reload
	@$(OPKG) list --size 2>/dev/null

package_install: FORCE
	@echo
	@echo Installing packages...
	$(OPKG) install $(firstword $(wildcard $(PACKAGE_DIR)/libc_*.ipk $(PACKAGE_DIR)/base/libc_*.ipk))
	$(OPKG) install $(firstword $(wildcard $(PACKAGE_DIR)/kernel_*.ipk $(PACKAGE_DIR)/base/kernel_*.ipk))
	$(OPKG) install $(BUILD_PACKAGES)
	rm -f $(TARGET_DIR)/usr/lib/opkg/lists/*

copy_files: FORCE
	@echo
	@echo Copying extra files
	@$(call file_copy,$(USER_FILES)/*,$(TARGET_DIR)/)

package_postinst: FORCE
	@echo
	@echo Cleaning up
	@rm -f $(TARGET_DIR)/tmp/opkg.lock
	@echo
	@echo Activating init scripts
	@mkdir -p $(TARGET_DIR)/etc/rc.d
	@( \
		cd $(TARGET_DIR); \
		for script in ./usr/lib/opkg/info/*.postinst; do \
			IPKG_INSTROOT=$(TARGET_DIR) $$(which bash) $$script; \
		done || true \
	)
	rm -f $(TARGET_DIR)/usr/lib/opkg/info/*.postinst
	$(if $(CONFIG_CLEAN_IPKG),rm -rf $(TARGET_DIR)/usr/lib/opkg)

build_image: FORCE
	@echo
	@echo Building images...
	$(NO_TRACE_MAKE) -C target/linux/$(BOARD)/image install TARGET_BUILD=1 IB=1 EXTRA_IMAGE_NAME="$(EXTRA_IMAGE_NAME)" \
		$(if $(USER_PROFILE),PROFILE="$(USER_PROFILE)")

checksum: FORCE
	@echo
	@echo Calculating checksums...
	@$(call sha256sums,$(BIN_DIR))

clean:
	rm -rf $(TMP_DIR) $(DL_DIR) $(TARGET_DIR) $(BIN_DIR)


info:
	(unset PROFILE FILES PACKAGES MAKEFLAGS; $(MAKE) -s _call_info)

PROFILE_FILTER = $(filter DEVICE_$(PROFILE) $(PROFILE),$(PROFILE_NAMES))

image:
ifneq ($(PROFILE),)
  ifeq ($(PROFILE_FILTER),)
	@echo 'Profile "$(PROFILE)" does not exist!'
	@echo 'Use "make info" to get a list of available profile names.'
	@exit 1
  endif
endif
	(unset PROFILE FILES PACKAGES MAKEFLAGS; \
	$(MAKE) -s _call_image \
		$(if $(PROFILE),USER_PROFILE="$(PROFILE_FILTER)") \
		$(if $(FILES),USER_FILES="$(FILES)") \
		$(if $(PACKAGES),USER_PACKAGES="$(PACKAGES)") \
		$(if $(BIN_DIR),BIN_DIR="$(BIN_DIR)"))

.SILENT: help info image

