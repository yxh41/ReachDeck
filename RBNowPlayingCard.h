// Now-playing card — glanceable transport controls for whatever is playing.
// Data source: MediaRemote, resolved with dlopen/dlsym at runtime (linking it
// directly would make the whole dylib fail to load on a version where the
// symbols moved, which costs a Safe Mode instead of a missing card).
// Nothing here reads or logs media metadata beyond track numbers: the title and
// artist are shown on screen and never written to debug.log.

#import <UIKit/UIKit.h>
#import "RBCardProtocol.h"

@interface RBNowPlayingCard : NSObject <RBCard>

/// Shared appearance settings; same semantics as RBPrivacyCard.
- (void)setStyleOpacity:(CGFloat)opacity corner:(CGFloat)corner border:(CGFloat)border compact:(BOOL)compact;

@end
