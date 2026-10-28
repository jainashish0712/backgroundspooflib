TARGET := iphone:clang:latest:14.0
ARCHS := arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = InstagramKeepAlive

InstagramKeepAlive_FILES = InstagramKeepAlive.mm
InstagramKeepAlive_CFLAGS = -fobjc-arc -O3 -std=c++17
InstagramKeepAlive_FRAMEWORKS = Foundation UIKit
InstagramKeepAlive_LIBRARIES = c++

include $(THEOS_MAKE_PATH)/tweak.mk
