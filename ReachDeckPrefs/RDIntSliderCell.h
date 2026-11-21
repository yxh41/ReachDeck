#import <UIKit/UIKit.h>
#import <Preferences/PSSliderCell.h>

// Native PSSliderCell formats its showValue label with "%.1f" and pins it to the
// right edge of a grouped cell, where the rounded corner clips the last digit.
// This subclass keeps the system slider + specifier binding intact, but rewrites
// the value as an integer and nudges the label left of the corner clip region.
@interface RDIntSliderCell : PSSliderCell
@end
