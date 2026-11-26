// Clipboard history card — keeps a short in-memory list of recent clipboard
// items (text / image / link) and restores any of them with a single tap.
// Contents are never written to disk and never logged (only type + length),
// matching the privacy stance of the original single-item card.

#import <UIKit/UIKit.h>
#import "RBCardProtocol.h"

@interface RBClipboardCard : NSObject <RBCard>

/// Shared appearance settings; same semantics as RBPrivacyCard.
- (void)setStyleOpacity:(CGFloat)opacity corner:(CGFloat)corner border:(CGFloat)border compact:(BOOL)compact;

@end
