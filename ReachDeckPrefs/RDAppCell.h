#import <Preferences/PSTableCell.h>

// Row for the app picker: icon on the left, name, checkmark when chosen.
// Bound from the picker's specifier via cellClass. The icon is handed in as a
// specifier property once the background decode finishes, so this cell never
// touches LaunchServices itself.
@interface RDAppCell : PSTableCell
@end
