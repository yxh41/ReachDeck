#import "RDBaseListController.h"

// Picker for the "app launcher" card: choose up to four installed apps.
// Nothing here talks to SpringBoard -- it only writes a bundle-ID array into the
// same plist the tweak already reads, and posts the same Darwin notification, so
// the new list is live the next time the panel appears (no respring).

@interface RDAppPickerController : RDBaseListController
@end
