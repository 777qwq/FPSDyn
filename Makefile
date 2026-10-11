THEOS_DEVICE_SIM =
TARGET := iphone:16.5:14.0
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = FPSDyn
FPSDyn_FILES = FPSDyn.m
FPSDyn_FRAMEWORKS = UIKit Foundation QuartzCore
FPSDyn_CFLAGS = -fobjc-arc -Wno-deprecated-declarations

BUNDLE_NAME = FPSDynPrefs
FPSDynPrefs_FILES = FPSDynPrefs/RootListController.m
FPSDynPrefs_INSTALL_PATH = /Library/PreferenceBundles
FPSDynPrefs_FRAMEWORKS = UIKit Foundation
FPSDynPrefs_PRIVATE_FRAMEWORKS = Preferences
FPSDynPrefs_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/bundle.mk
