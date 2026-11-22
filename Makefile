ARCHS = arm64 arm64e
TARGET := iphone:clang:16.5:15.0
INSTALL_TARGET_PROCESSES = SpringBoard

DEBUG = 0
FINALPACKAGE = 1
THEOS_PACKAGE_SCHEME = roothide

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = ReachDeck
ReachDeck_FILES = Tweak.xm RBPrivacyCard.m RBClipboardCard.m RBNowPlayingCard.m
ReachDeck_CFLAGS = -fobjc-arc -Werror -Wall
ReachDeck_EXTRA_FRAMEWORKS =

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += ReachDeckPrefs
include $(THEOS_MAKE_PATH)/aggregate.mk
