#import <UIKit/UIKit.h>

// Picker for the "app launcher" card: choose up to four installed apps.
//
// Plain UIKit on purpose. An earlier build drove this screen from a
// PSListController subclass with a custom cellClass, and Preferences.framework
// threw inside its own cell factory while the table first laid out -- a SIGABRT
// no app-side guard can catch, because the throw happens in closed code between
// "specifier exists" and "cell returned". A bare UITableViewController has no
// such seam: we own the data source, the cells and the layout.
//
// Nothing here talks to SpringBoard. It only writes a bundle-ID array into the
// plist the tweak already reads and posts the same Darwin notification, so the
// new list is live the next time the panel appears (no respring).

@interface RDAppPickerController : UIViewController
@end
