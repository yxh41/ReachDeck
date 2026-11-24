// 0.6.6: plain UIKit page for reordering the ReachDeck cards.
// Deliberately NOT a PSListController with custom cells -- that path crashed
// Preferences on iOS 16 (see RDAppPickerController's history).

#import <UIKit/UIKit.h>

@interface RDCardOrderController : UIViewController
@end
