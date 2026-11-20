ARCHS = arm64 arm64e
TARGET := iphone:clang:latest:15.0

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = ReachDeckPrefs
ReachDeckPrefs_FILES = RDBaseListController.m RDRootListController.m
ReachDeckPrefs_INSTALL_PATH = /Library/PreferenceBundles
ReachDeckPrefs_FRAMEWORKS = UIKit
ReachDeckPrefs_PRIVATE_FRAMEWORKS = Preferences
ReachDeckPrefs_CFLAGS = -fobjc-arc -Werror -Wall

include $(THEOS_MAKE_PATH)/bundle.mk
