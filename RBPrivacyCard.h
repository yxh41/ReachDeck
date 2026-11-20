// Privacy card — "who is using the camera / microphone right now".
// Data source: SpringBoard's own SBSensorActivityDataProvider. No app-process hooking needed.
// Verified against runtime headers (iOS 17/18) and maybeDazy/Tweaks on iOS 16.4.1.

#import <UIKit/UIKit.h>
#import "RBCardProtocol.h"

// Shared ReachDeck diagnostic logger: writes both syslog and the debug.log
// plist-dir file, so card-side parsing evidence is visible in the same log the
// tweak side writes. Implemented in Tweak.xm.
//
// Tweak.xm is compiled as Objective-C++ (clang++) while RBPrivacyCard.m is
// plain Objective-C (clang), so this symbol MUST have C linkage on both sides.
#ifdef __cplusplus
extern "C" {
#endif
extern void RBLog(NSString * _Nonnull fmt, ...) NS_FORMAT_FUNCTION(1, 2);
#ifdef __cplusplus
}
#endif

@interface RBPrivacyCard : NSObject <RBCard>

/// Called from the tweak side when sensor activity changes.
/// attributions = active + recent sources; activeAttributions = active only.
/// Passing nil clears the card.
- (void)ingestAttributions:(nullable NSSet *)attributions
         activeAttributions:(nullable NSSet *)activeAttributions;

/// When YES, system-service attributions (no bundle / isSystemService) are filtered out.
- (void)setHideSystemServices:(BOOL)hide;

@end
