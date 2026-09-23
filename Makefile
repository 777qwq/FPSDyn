THEOS_DEVICE_SIM =
TARGET := iphone:16.5:14.0
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = FPSDyn
FPSDyn_FILES = FPSDyn.m
FPSDyn_FRAMEWORKS = UIKit Foundation QuartzCore
FPSDyn_CFLAGS = -fobjc-arc -Wno-deprecated-declarations

include $(THEOS_MAKE_PATH)/tweak.mk
