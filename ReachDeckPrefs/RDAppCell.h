#import <UIKit/UIKit.h>

// Row for the app picker: icon on the left, name, and the selection order on the
// right. A plain UITableViewCell -- see the note in RDAppPickerController.h for
// why this is not a PSTableCell anymore.
@interface RDAppCell : UITableViewCell

/// order == 0 means "not selected"; otherwise 1...4, shown as a blue badge.
- (void)configureWithName:(NSString *)name icon:(UIImage *)icon order:(NSUInteger)order;

@end
