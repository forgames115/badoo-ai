TARGET := iphone:clang:16.5:15.0
ARCHS = arm64 arm64e
THEOS_PACKAGE_SCHEME = rootless
INSTALL_TARGET_PROCESSES = Badoo

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = BadooAI
BadooAI_FILES = Tweak.xm
BadooAI_CFLAGS = -fobjc-arc -Wno-unused-variable -Wno-deprecated-declarations
BadooAI_FRAMEWORKS = UIKit Foundation CoreFoundation
BadooAI_LIBRARIES = sqlite3

include $(THEOS_MAKE_PATH)/tweak.mk
