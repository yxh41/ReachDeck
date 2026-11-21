#import <UIKit/UIKit.h>

// The roothide SDK ships PSListController.h / PSSpecifier.h but NOT the private
// cell headers (Preferences/PSSliderCell.h is absent -> "file not found").
// Declare the minimal interface we subclass locally: the compiler only needs
// the ancestor chain down to UITableViewCell so inherited accessors
// (contentView / textLabel / detailTextLabel) type-check. At runtime objc
// resolves the real PSSliderCell class (which inherits PSTableCell) by name,
// so [super ...] and all native slider logic still work unchanged.
@interface PSSliderCell : UITableViewCell
@end

// Native PSSliderCell formats its showValue label with "%.1f" and pins it to the
// right edge of a grouped cell, where the rounded corner clips the last digit.
// This subclass keeps the system slider + specifier binding intact, but rewrites
// the value as an integer string and nudges the label left of the corner clip.
@interface RDIntSliderCell : PSSliderCell
@end
