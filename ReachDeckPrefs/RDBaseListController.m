#import "RDBaseListController.h"

#define RD_NOTIFY "com.zlhkf.ReachDeck.settings"

// rootful / rootless / roothide: probe the DIRECTORY, not the file. On a fresh
// install the plist does not exist yet; probing the file would fall through to
// /var/jb (not the roothide jbroot, so it does not exist) and every write would
// be silently lost. Keep the two files byte-for-byte identical in logic.
#define RDPlistPath ([[NSFileManager defaultManager] fileExistsAtPath:@"/var/mobile/Library/Preferences"] ? @"/var/mobile/Library/Preferences/com.zlhkf.ReachDeck.plist" : @"/var/jb/var/mobile/Library/Preferences/com.zlhkf.ReachDeck.plist")

@implementation RDBaseListController

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSDictionary *settings = [NSDictionary dictionaryWithContentsOfFile:RDPlistPath];
    id value = settings[specifier.properties[@"key"]];
    return value ?: specifier.properties[@"default"];
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    // Read-modify-write a single key. Constructing a fresh dict here would wipe the
    // other switches whenever one is toggled.
    NSMutableDictionary *settings = [NSMutableDictionary dictionary];
    [settings addEntriesFromDictionary:[NSDictionary dictionaryWithContentsOfFile:RDPlistPath]];
    [settings setObject:value forKey:specifier.properties[@"key"]];
    [settings writeToFile:RDPlistPath atomically:YES];

    [super setPreferenceValue:value specifier:specifier];

    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        CFSTR(RD_NOTIFY), NULL, NULL, TRUE);
}

@end
