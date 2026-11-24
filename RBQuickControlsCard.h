// Quick controls card — toggles you would otherwise reach the top for:
// flashlight, ringer mute, low power, dark mode, orientation lock, lock screen,
// screen recording, media mute, location (0.6.4 added the last three).
//
// SAFETY CONTRACT (learned from the vcamx drawer action work):
//   * Every private class is resolved lazily via dlopen + objc_getClass, and
//     every call is guarded by respondsToSelector. A missing API degrades to
//     "this tile does nothing and says so in the log", never to a crash.
//   * No selector name is guessed. The names here are the ones dump-probed and
//     verified on device in vcamx (718/720/721/723).
//   * Every write is followed by a read-back 0.6s later; the log says whether
//     the state actually flipped, not whether the call returned.

#import <UIKit/UIKit.h>
#import "RBCardProtocol.h"

@interface RBQuickControlsCard : NSObject <RBCard>

/// Shared appearance settings; rebuilds the card UI so changes apply without a respring.
- (void)setStyleOpacity:(CGFloat)opacity corner:(CGFloat)corner border:(CGFloat)border compact:(BOOL)compact;

@end
