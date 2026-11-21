#import <Preferences/PSTableCell.h>

// A Lumen-style slider row: title + numeric value on the first line, slider on
// the second. Inherits PSTableCell (a real SDK symbol, unlike PSSliderCell which
// the roothide SDK neither ships a header for nor exports for linking), and is
// bound from Root.plist via cellClass. All config comes from the specifier.
@interface RDSliderCell : PSTableCell
@end
