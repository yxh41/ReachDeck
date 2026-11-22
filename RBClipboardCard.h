// Clipboard card — glanceable, masked by default.
// It never persists clipboard contents and never logs them.

#import <UIKit/UIKit.h>
#import "RBCardProtocol.h"

@interface RBClipboardCard : NSObject <RBCard>

/// Shared appearance settings; same semantics as RBPrivacyCard.
- (void)setStyleOpacity:(CGFloat)opacity corner:(CGFloat)corner border:(CGFloat)border compact:(BOOL)compact;

@end
