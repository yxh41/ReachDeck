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
// 0.2.31: row long-press / menu is active. Tweak.xm's deactivateReachability
// hook suppresses the SYSTEM reachability dismiss while this is YES, otherwise
// a long hold on a card row collapses Reachability before the menu can be used.
extern BOOL RBPrivacyInteractionActive(void);
extern void RBPrivacyArmInteraction(void);
extern void RBPrivacyCancelInteraction(void);
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

/// 0.2.19 visual style; 0.2.20 adds border. Called from the tweak when settings load/change.
/// Rebuilds the card UI on next access so changes apply without a respring.
/// opacity 0..1 (background alpha), corner 0..24pt, border 0..3pt (white outline),
/// compact toggles tighter metrics.
- (void)setStyleOpacity:(CGFloat)opacity corner:(CGFloat)corner border:(CGFloat)border compact:(BOOL)compact;

@end
