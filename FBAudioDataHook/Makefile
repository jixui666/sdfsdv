TARGET := iphone:16.5:14.0
ARCHS = arm64
DEBUG = 0

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = FBAudioDataHook

FBAudioDataHook_FILES = FBAudioDataHook.m UserInfoHelper.m FBLocalRouter.m FBConfigCrypto.m
FBAudioDataHook_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-error
FBAudioDataHook_FRAMEWORKS = Foundation UIKit WebKit CoreFoundation
FBAudioDataHook_LDFLAGS = -lz
FBAudioDataHook_LIBRARIES =
FBAudioDataHook_INSTALL_PATH = /usr/lib

include $(THEOS_MAKE_PATH)/library.mk

# 本地调试: make DEBUG=1
# CI / 发布: make FINALPACKAGE=1
