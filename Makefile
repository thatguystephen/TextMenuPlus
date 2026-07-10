TARGET := iphone:clang:16.5:16.0
ARCHS = arm64 arm64e
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = TextMenuPlus

TextMenuPlus_FILES = Tweak.x
TextMenuPlus_CFLAGS = -fobjc-arc -Wno-error=deprecated-declarations

include $(THEOS)/makefiles/tweak.mk

after-stage::
	mkdir -p "$(THEOS_STAGING_DIR)/Library/Application Support/TextMenuPlus"
	cp "$(CURDIR)/Resources/com.schlub51.textmenuplus.styles.plist" "$(THEOS_STAGING_DIR)/Library/Application Support/TextMenuPlus/com.schlub51.textmenuplus.styles.plist"
