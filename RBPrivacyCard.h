// Privacy card — "who is using the camera / microphone right now".
// Data source: SpringBoard's own SBSensorActivityDataProvider. No app-process hooking needed.
// Verified against runtime headers (iOS 17/18) and maybeDazy/Tweaks on iOS 16.4.1.

#import <UIKit/UIKit.h>
#import "RBCardProtocol.h"

@interface RBPrivacyCard : NSObject <RBCard>

/// Called from the tweak side when sensor activity changes. Pass the raw attribution set
/// (a NSSet of SBSensorActivityAttribution) or nil to clear.
- (void)ingestAttributions:(nullable NSSet *)attributions;

/// When YES, system-service attributions (no bundle / isSystemService) are filtered out.
- (void)setHideSystemServices:(BOOL)hide;

@end
