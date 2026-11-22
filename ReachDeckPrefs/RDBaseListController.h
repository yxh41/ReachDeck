// Shared PSListController base for all ReachDeck preference panes.
// Centralises plist I/O and the Darwin notification so no pane duplicates it.

#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>

@interface RDBaseListController : PSListController

/// Whole settings dictionary as currently on disk (never nil).
+ (NSMutableDictionary *)rdSettings;

/// Read-modify-write ONE key and post the Darwin notification. A nil value
/// removes the key, which is how "no custom app list" is expressed. Building a
/// fresh dictionary here would wipe every other switch, so this always merges.
+ (void)rdSetValue:(id)value forKey:(NSString *)key;

@end
