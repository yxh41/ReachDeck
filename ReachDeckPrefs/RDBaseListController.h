// Shared PSListController base for all ReachDeck preference panes.
// Centralises plist I/O and the Darwin notification so no pane duplicates it.

#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>

@interface RDBaseListController : PSListController
@end
