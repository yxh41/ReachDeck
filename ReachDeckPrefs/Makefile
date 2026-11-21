ARCHS = arm64 arm64e
TARGET := iphone:clang:16.5:15.0

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = ReachDeckPrefs
ReachDeckPrefs_FILES = RDBaseListController.m RDRootListController.m RDSliderCell.m
ReachDeckPrefs_INSTALL_PATH = /Library/PreferenceBundles
ReachDeckPrefs_FRAMEWORKS = UIKit
ReachDeckPrefs_PRIVATE_FRAMEWORKS = Preferences
ReachDeckPrefs_CFLAGS = -fobjc-arc -Werror -Wall
# roothide Theos does not add the SDK's PrivateFrameworks dir for PRIVATE_FRAMEWORKS;
# point ld at it explicitly or -framework Preferences cannot be resolved.
ReachDeckPrefs_LDFLAGS += -F$(THEOS)/sdks/iPhoneOS16.5.sdk/System/Library/PrivateFrameworks
# cellClass custom cells (RDSliderCell : PSTableCell) are instantiated by the
# Preferences host; let any host-only symbols resolve at runtime (same as Lumen).
ReachDeckPrefs_LDFLAGS += -undefined dynamic_lookup

include $(THEOS_MAKE_PATH)/bundle.mk
