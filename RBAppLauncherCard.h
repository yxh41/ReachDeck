// Dock apps card — the four apps sitting in the Dock, one tap to launch.
// Reads the icons out of SpringBoard's own icon model (no app-side hooking),
// then launches through SpringBoardServices exactly like the media card does.
// Nothing here needs an entitlement, a URL scheme, or a network round trip.

#import <UIKit/UIKit.h>
#import "RBCardProtocol.h"

@interface RBAppLauncherCard : NSObject <RBCard>

/// Shared appearance settings; rebuilds the card UI so changes apply without a respring.
- (void)setStyleOpacity:(CGFloat)opacity corner:(CGFloat)corner border:(CGFloat)border compact:(BOOL)compact;

@end
