#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>
#import <stdarg.h>
#import <stdlib.h>
#import <string.h>
#import "RBCardProtocol.h"
#import "RBPrivacyCard.h"
#import "RBClipboardCard.h"
#import "RBNowPlayingCard.h"

// Diagnostic log (0.0.3+): ASCII-only strings so they survive toolchain string
// handling; mirrored to syslog and a plist-dir file the user can send us.
// Foundation-only — never reaches UIKit, so it stays safe inside %ctor.
static NSString *RBLogPath(void) {
    NSString *a = @"/var/mobile/Library/Preferences/com.zlhkf.ReachDeck.debug.log";
    NSString *b = @"/var/jb/var/mobile/Library/Preferences/com.zlhkf.ReachDeck.debug.log";
    return [[NSFileManager defaultManager] fileExistsAtPath:@"/var/mobile/Library/Preferences"] ? a : b;
}
#ifdef __cplusplus
extern "C"
#endif
void RBLog(NSString * _Nonnull fmt, ...) {
    va_list args; va_start(args, fmt);
    NSString *body = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    // 0.2.17: relative ms since process start, so the 5s gap can be localized.
    static CFAbsoluteTime t0 = 0;
    if (t0 == 0) t0 = CFAbsoluteTimeGetCurrent();
    long ms = (long)((CFAbsoluteTimeGetCurrent() - t0) * 1000.0);
    NSString *msg = [NSString stringWithFormat:@"+%ldms %@", ms, body];
    NSLog(@"[ReachDeck] %@", msg);
    NSString *line = [msg stringByAppendingString:@"\n"];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:RBLogPath()];
    if (fh) { [fh seekToEndOfFile]; [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [fh closeFile]; }
    else { [line writeToFile:RBLogPath() atomically:YES encoding:NSUTF8StringEncoding error:nil]; }
}
static void RBLogReset(void) {
    [@"" writeToFile:RBLogPath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

// Self-evidence helpers: dump real class names containing "Reachability" and a
// class's ivar list. Called only from %ctor; no behavior change.
static void RBDumpReachabilityClasses(void) {
    int n = objc_getClassList(NULL, 0);
    if (n <= 0) return;
    Class *classes = (Class *)malloc(sizeof(Class) * (size_t)n);
    if (!classes) return;
    n = objc_getClassList(classes, n);
    NSMutableString *hits = [NSMutableString string];
    for (int i = 0; i < n; i++) {
        const char *nm = class_getName(classes[i]);
        if (nm && strstr(nm, "Reachability")) [hits appendFormat:@"%s ", nm];
    }
    free(classes);
    RBLog(@"reachability classes: %@", hits);
}
static void RBDumpIvars(const char *clsName) {
    Class cls = objc_getClass(clsName);
    if (!cls) { RBLog(@"ivars %s: CLASS MISSING", clsName); return; }
    unsigned int count = 0;
    Ivar *ivars = class_copyIvarList(cls, &count);
    NSMutableString *s = [NSMutableString string];
    for (unsigned int i = 0; i < count; i++) {
        const char *nm = ivar_getName(ivars[i]);
        if (nm) [s appendFormat:@"%s ", nm];
    }
    free(ivars);
    RBLog(@"ivars %s: %@", clsName, s);
}

// ============================================================================
// ReachDeck — pluggable HUD for the Reachability window's empty half.
//
// Mount point and reachability-forcing hooks are adapted from ReachPlayer 2.6
// (nahtedetihw/ReachPlayer), which is proven on iOS 13-16.4.
// Privacy data source is SpringBoard's own SBSensorActivityDataProvider, whose
// interface was verified from runtime headers and whose presence on iOS 16.4.1
// was measured by maybeDazy/Tweaks (the six indicator UI classes are NOT there —
// do not hook them).
//
// Design rules carried over from the project's hard-won conventions:
//  - Every private class is guarded by objc_getClass() before %init.
//  - Avoid every deprecated window-access API; CI compiles with -Werror.
//  - Sensor data is read passively; we NEVER swallow _handleNewDomainData:
//    (calling %orig unconditionally) so we cannot break the native privacy dot.
//  - SAFE MODE FIX (0.0.2): %ctor only reads plain data and installs hooks.
//    No UIView / UIStackView / UILabel / UIColor / UIFont / Auto Layout object
//    may be constructed before UIApplication is ready. Cards stay state-only
//    until the first Reachability presentation builds their UI lazily.
// ============================================================================

#define RB_NOTIFY "com.zlhkf.ReachDeck.settings"

// Check the DIRECTORY, not the file: on a fresh install the plist does not exist
// yet, and probing the file would wrongly fall through to /var/jb (which is not
// the roothide jbroot and does not exist), silently losing every setting write.
#define RBPlistPath ([[NSFileManager defaultManager] fileExistsAtPath:@"/var/mobile/Library/Preferences"] ? @"/var/mobile/Library/Preferences/com.zlhkf.ReachDeck.plist" : @"/var/jb/var/mobile/Library/Preferences/com.zlhkf.ReachDeck.plist")

static RBPrivacyCard *privacyCard = nil;
static RBClipboardCard *clipboardCard = nil;
static RBNowPlayingCard *nowPlayingCard = nil;
static BOOL rbEnabled = YES;
static BOOL rbCardPrivacy = YES;
static BOOL rbCardClipboard = YES;
static BOOL rbCardNowPlaying = YES;
static BOOL rbHideSystemServices = NO;
static BOOL rbCardAtBottom = YES;         // 0.2.1: derived from cardAtTop (default off => bottom)
// 0.2.19 style: defaults reproduce the pre-style look exactly.
static CGFloat rbStyleOpacity = 0.72;
static CGFloat rbStyleCorner = 16;
static CGFloat rbStyleBorder = 1;         // 0.2.20: white border width (0..3)
static BOOL rbStyleCompact = NO;
static NSArray<id<RBCard>> *rbCards = nil;
static UIView *rbContainer = nil;        // container mounted inside _topWallpaperEffectView
static NSUInteger rbHitTestLogCount = 0; // bounded self-evidence for the touch bridge
static UIView *rbStickyRow = nil;        // ReachPlayer emptyView trick: keep down/up on one view
static NSUInteger rbCurrentCardIndex = 0; // 0.3.0: deck selection
static NSArray<id<RBCard>> *rbSortedCards = nil;
// 0.3.3 card stack, "grabber + depth":
//   rear card   decorative card behind the front one (never interactive); it is
//               a plain rounded rect on purpose -- a real card view would bring
//               its own rows and hitTest and steal touches from underneath
//   rbPeekTap   the grabber pill, sitting ENTIRELY on the rear band at its left
//               edge (0.3.5: it used to straddle the shared edge, centred)
//   rbPeekLabel next card's short name inside that pill
// 0.3.5: 14 -> 22. The pill is 15pt tall and must not cross the seam, so the
// band has to be tall enough to host it with ~3.5pt of padding above and below.
static CGFloat const kRBPeekOffset = 22.0; // how far the rear card sticks out
static UIControl *rbPeekTap = nil;
static UILabel *rbPeekLabel = nil;
// 0.4.0: page dots on the band's right side. The pill only says "tap for the
// next card", which stops being enough at three cards -- you cannot tell where
// you are in the cycle, so the dots carry the position and the pill keeps the
// action. Decorative only: never tagged, never interactive.
static UIStackView *rbPeekDots = nil;
// 0.3.1: geometry the deck is allowed to occupy on the current presentation.
// Kept as statics because viewDidAppear re-measures after the reachability
// animation settles (at viewWillAppear the host is not in a window yet).
static UIStackView *rbStackView = nil;
static NSLayoutConstraint *rbStackTopConstraint = nil;

// Rebuild the active card list from prefs. Cards are created once and reused; only
// membership changes. This keeps sensor state intact across preference toggles.
// NOTE: allocating a card is safe here (state only); its UI is built lazily.
static void RBRebuildCards(void) {
    NSMutableArray *cards = [NSMutableArray array];
    if (rbCardPrivacy) {
        if (!privacyCard) privacyCard = [[RBPrivacyCard alloc] init];
        [privacyCard setHideSystemServices:rbHideSystemServices];
        [cards addObject:privacyCard];
    }
    if (rbCardNowPlaying) {
        if (!nowPlayingCard) nowPlayingCard = [[RBNowPlayingCard alloc] init];
        [cards addObject:nowPlayingCard];
    }
    if (rbCardClipboard) {
        if (!clipboardCard) clipboardCard = [[RBClipboardCard alloc] init];
        [cards addObject:clipboardCard];
    }
    for (id<RBCard> card in cards) {
        if ([card respondsToSelector:@selector(setStyleOpacity:corner:border:compact:)]) {
            [card setStyleOpacity:rbStyleOpacity corner:rbStyleCorner
                           border:rbStyleBorder compact:rbStyleCompact];
        }
    }
    rbCards = [cards copy];
    RBLog(@"rebuild cards privacy=%d nowplaying=%d clipboard=%d hideSys=%d bottom=%d count=%lu",
          rbCardPrivacy, rbCardNowPlaying, rbCardClipboard, rbHideSystemServices,
          rbCardAtBottom, (unsigned long)rbCards.count);
}

// Pure data read — safe from a dylib initializer: Foundation file I/O only,
// no UIKit and no class hooks.
static void RBReadPrefs(void) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:RBPlistPath];
    rbEnabled = d[@"enabled"] ? [d[@"enabled"] boolValue] : YES;
    rbCardPrivacy = d[@"cardPrivacy"] ? [d[@"cardPrivacy"] boolValue] : YES;
    rbCardNowPlaying = d[@"cardNowPlaying"] ? [d[@"cardNowPlaying"] boolValue] : YES;
    rbCardClipboard = d[@"cardClipboard"] ? [d[@"cardClipboard"] boolValue] : YES;
    rbHideSystemServices = d[@"hideSystemServices"] ? [d[@"hideSystemServices"] boolValue] : NO;
    // 0.2.1: the UI switch is "cardAtTop" (off = bottom, the visible band on this
    // device). Honour the old cardAtBottom key too for users upgrading from 0.1.x.
    rbCardAtBottom = d[@"cardAtTop"] ? ![d[@"cardAtTop"] boolValue]
                   : (d[@"cardAtBottom"] ? [d[@"cardAtBottom"] boolValue] : YES);
    // 0.2.20: opacity slider now stores an INTEGER percentage (20..100). A value
    // <= 1.0 is the legacy 0.2.19 fractional format (0.72) -- migrate by treating
    // it as already-normalized. This keeps existing users' appearance identical.
    CGFloat op = d[@"cardOpacity"] ? [d[@"cardOpacity"] floatValue] : 72;
    CGFloat opFrac = (op <= 1.0) ? op : (op / 100.0);
    rbStyleOpacity = opFrac < 0.2 ? 0.2 : (opFrac > 1.0 ? 1.0 : opFrac);
    CGFloat cr = d[@"cardCorner"] ? [d[@"cardCorner"] floatValue] : 16;
    rbStyleCorner = cr < 0 ? 0 : (cr > 24 ? 24 : cr);
    CGFloat bd = d[@"cardBorder"] ? [d[@"cardBorder"] floatValue] : 1;
    rbStyleBorder = bd < 0 ? 0 : (bd > 3 ? 3 : bd);
    rbStyleCompact = d[@"cardCompact"] ? [d[@"cardCompact"] boolValue] : NO;
}

// Darwin callback. The Reachability view only exists while the window is up, so
// "immediate" means: next present builds from the new config. No respring needed.
// We never reach into the live view here — finding the reachability controller from
// a scene graph is fragile, and the next viewWillAppear already handles remounting.

static UIView *rbTopEffect = nil;
static id rbLiveController = nil;

static void RBReloadSettings(void) {
    RBReadPrefs();
    RBRebuildCards();
    // Rebuild in place while reachability is up; otherwise the next appear does it.
    dispatch_async(dispatch_get_main_queue(), ^{
        if (rbLiveController && rbTopEffect) {
            RBLog(@"reload: remount on %@ bottom=%d", NSStringFromClass([rbTopEffect class]), (int)rbCardAtBottom);
            [rbLiveController performSelector:@selector(addRBContainer)];
        } else {
            RBLog(@"reload: no active reachability, apply on next appear");
        }
    });
}

// Where the overlay lives. Three attempts settled this:
// 0.0.4/0.0.5 used _topWallpaperEffectView -> it sits at y=-749, off-screen (win=0).
// 0.0.8 borrowed the highest-level window -> another tweak's private window (1e11).
// 0.0.9 owned a window at UIWindowLevelAlert+20 -> correct card, but it outlived
// reachability, because that window has no lifecycle tie to reachability at all.
// The answer was in the 0.0.8 window dump the whole time: SBReachabilityWindow
// (level 1114) exists exactly as long as reachability does, and it is the surface
// reachability itself paints on. Mounting inside it makes show/hide automatic.
// ---- Private SpringBoard interfaces ----
@interface SBReachabilityManager : NSObject
+ (id)sharedInstance;
- (void)toggleReachability;
- (BOOL)reachabilityModeActive;
- (void)deactivateReachability;
- (void)_notifyObserversReachabilityYOffsetDidChange;
@end

@interface SBReachabilitySettings : NSObject
- (double)yOffsetFactor;
- (BOOL)allowOnAllDevices;
@end

@interface SBReachabilityBackgroundView : UIView
@end

@interface SBReachabilityWindow : UIWindow
@end

@class RBReachDeckPeekButton;

@interface SBReachabilityBackgroundViewController : UIViewController
- (void)addRBContainer;
- (void)rbPeekTouchDown:(RBReachDeckPeekButton *)sender;
- (void)rbPeekTouchUp:(RBReachDeckPeekButton *)sender;
- (void)rbPeekTouchCancel:(RBReachDeckPeekButton *)sender;
- (void)rbShowCardAtIndex:(NSUInteger)index;
- (void)rbPeekNameForIndex:(NSUInteger)index;
- (void)rbUpdatePeekDots;
- (void)rbUpdateUsableGeometry;
@end

// SBSensorActivityDataProvider — read-only, exact selectors we call.
@interface SBSensorActivityDataProvider : NSObject
- (NSSet *)activeCameraAndMicrophoneActivityAttributions;
- (NSSet *)activeAndRecentSensorActivityAttributions;
@end

// ============================================================================
#pragma mark - Card container

// 0.3.2: card-stack presentation. The card behind the front one only shows an
// 18pt sliver along the top edge; that sliver IS the switcher. It reuses the
// 'RDB4' tag the 0.3.0 rail used, so the hitTest bridge needs no new entry.
@interface RBReachDeckPeekButton : UIControl
@end
@implementation RBReachDeckPeekButton
@end

// 0.3.5: the front card's drop shadow.
// It cannot live on the card's own layer: every card root is clipsToBounds with
// a corner radius, so layer.shadow* is clipped away outright. A separate shadow
// HOST view would be worse -- it paints a blurred copy of the whole path,
// interior included, and at 20% card opacity that reads as the ghost rectangle
// 0.3.4 spent a build killing. So the shadow is drawn only where it is visible:
// a top-down dark gradient confined to the rear band, sitting between the band
// and the front card. Backing layer is the gradient itself, so it resizes with
// the view and no layoutSubviews bookkeeping is needed.
@interface RBReachDeckShadowView : UIView
@end
@implementation RBReachDeckShadowView
+ (Class)layerClass {
    return [CAGradientLayer class];
}
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.userInteractionEnabled = NO;
        self.opaque = NO;
        CAGradientLayer *g = (CAGradientLayer *)self.layer;
        g.colors = @[
            (id)[[UIColor blackColor] colorWithAlphaComponent:0.00].CGColor,
            (id)[[UIColor blackColor] colorWithAlphaComponent:0.09].CGColor,
            (id)[[UIColor blackColor] colorWithAlphaComponent:0.20].CGColor,
            (id)[[UIColor blackColor] colorWithAlphaComponent:0.33].CGColor,
        ];
        g.locations = @[ @0.0, @0.42, @0.74, @1.0 ];
        g.startPoint = CGPointMake(0.5, 0.0);
        g.endPoint = CGPointMake(0.5, 1.0);
    }
    return self;
}
@end

// The container spans the whole Reachability band, but only explicitly tagged
// card rows ('RDB1'), the long-press menu/overlay ('RDB2'), the show-all /
// collapse footer ('RDB3'), the card-stack sliver ('RDB4'), the clipboard card
// root ('RDB5'), the now-playing transport buttons ('RDB6') and the now-playing
// scrubber ('RDB7') consume touches. Everything else returns nil so Reachability
// gestures still pass through.
@interface RBReachDeckContainerView : UIView
@end
@implementation RBReachDeckContainerView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (!hit || hit == self) return nil;
    for (UIView *v = hit; v && v != self; v = v.superview) {
        // 'RDB1' row; 'RDB2' menu/overlay; 'RDB3' expand footer;
        // 'RDB4' card-stack sliver; 'RDB5' clipboard card root;
        // 'RDB6' now-playing transport button; 'RDB7' now-playing scrubber.
        if (v.tag == 0x52444231 || v.tag == 0x52444232 ||
            v.tag == 0x52444233 || v.tag == 0x52444234 ||
            v.tag == 0x52444235 || v.tag == 0x52444236 ||
            v.tag == 0x52444237) return hit;
    }
    return nil;
}
@end

%group RBContainer

%hook SBReachabilityBackgroundViewController

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    RBLog(@"viewWillAppear fired");
    rbLiveController = self;
    // THE missing step in 0.0.4-0.1.4, copied verbatim from ReachPlayer 2.6:
    // without this notification _topWallpaperEffectView stays at y == -749
    // (off-screen), so a correctly laid out card inside it is never visible.
    SBReachabilityManager *mgr = [%c(SBReachabilityManager) sharedInstance];
    if ([mgr respondsToSelector:@selector(_notifyObserversReachabilityYOffsetDidChange)]) {
        [mgr _notifyObserversReachabilityYOffsetDidChange];
        RBLog(@"viewWillAppear notified Y offset change");
    } else {
        RBLog(@"viewWillAppear manager lacks _notifyObserversReachabilityYOffsetDidChange");
    }
    [self addRBContainer];
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    if (!rbContainer) { RBLog(@"viewDidAppear: remount"); [self addRBContainer]; }
    // 0.3.1: first moment the host is guaranteed to be inside a window, so the
    // safe-area conversion is meaningful. The 0.45s re-measure after mount only
    // runs from addRBContainer, which may have fired before the animation.
    [self rbUpdateUsableGeometry];
}

- (void)viewWillDisappear:(BOOL)animated {
    %orig;
    // 0.2.31: clear the suppress flag on teardown so a menu left open from the
    // previous presentation cannot block a legitimate later deactivation.
    RBPrivacyCancelInteraction();
    // 0.2.34: session-only card state (e.g. the expanded row list) resets here.
    for (id<RBCard> card in rbCards) {
        if ([card respondsToSelector:@selector(rbWillUnmount)]) [card rbWillUnmount];
    }
    rbCurrentCardIndex = 0;
    rbSortedCards = nil;
    rbPeekTap = nil;
    rbPeekLabel = nil;
    rbPeekDots = nil;
    rbStackView = nil;
    rbStackTopConstraint = nil;
    rbLiveController = nil;
    rbTopEffect = nil;
    // 0.2.9: sticky row is a retained pointer into the container. Clear it on
    // teardown too, otherwise collapsing the sheet can leave a dangling pointer
    // that the next hitTest message-sends (SpringBoard crash / Safe Mode).
    rbStickyRow = nil;
    if (rbContainer) { [rbContainer removeFromSuperview]; rbContainer = nil; }
}

%new
- (void)addRBContainer {
    RBLog(@"addRBContainer enter enabled=%d cards=%lu", rbEnabled, (unsigned long)rbCards.count);
    if (!rbEnabled) { RBLog(@"addRBContainer bail: disabled"); return; }
    if (!rbCards) RBRebuildCards();
    if (rbCards.count == 0) { RBLog(@"addRBContainer bail: no cards"); return; }

    UIView *bg = self.view;
    if (![bg isKindOfClass:[UIView class]]) { RBLog(@"addRBContainer bail: no bg"); return; }

    // Exact mount point from ReachPlayer 2.6: _topWallpaperEffectView. It is the
    // surface that fills the exposed band; bg / windows / self-made windows are not.
    UIView *topEffect = MSHookIvar<UIView *>(bg, "_topWallpaperEffectView");
    RBLog(@"addRBContainer topEffect=%@ frame=%@ bounds=%@ win=%d",
          NSStringFromClass([topEffect class]),
          topEffect ? NSStringFromCGRect(topEffect.frame) : @"(nil)",
          topEffect ? NSStringFromCGRect(topEffect.bounds) : @"(nil)",
          (int)(topEffect.window != nil));
    if (!topEffect) { RBLog(@"addRBContainer bail: no topEffect"); return; }
    rbTopEffect = topEffect;
    // The wallpaper effect host is normally non-interactive; without this the
    // window hitTest bridge below cannot reach our card rows.
    topEffect.userInteractionEnabled = YES;

    // 0.2.9: sticky row is a retained pointer into the container. Clear it on
    // teardown too, otherwise collapsing the sheet can leave a dangling pointer
    // that the next hitTest message-sends (SpringBoard crash / Safe Mode).
    rbStickyRow = nil;
    if (rbContainer) { [rbContainer removeFromSuperview]; rbContainer = nil; }

    // ReachPlayer: frame = host.bounds + four equal edge constraints.
    RBReachDeckContainerView *container = [[RBReachDeckContainerView alloc] initWithFrame:topEffect.bounds];
    container.backgroundColor = [UIColor clearColor];
    container.userInteractionEnabled = YES;  // custom hitTest only accepts tagged rows
    [topEffect addSubview:container];
    container.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [container.topAnchor constraintEqualToAnchor:topEffect.topAnchor],
        [container.bottomAnchor constraintEqualToAnchor:topEffect.bottomAnchor],
        [container.leadingAnchor constraintEqualToAnchor:topEffect.leadingAnchor],
        [container.trailingAnchor constraintEqualToAnchor:topEffect.trailingAnchor],
    ]];

    NSArray<id<RBCard>> *sorted = [rbCards sortedArrayUsingComparator:^NSComparisonResult(id<RBCard> a, id<RBCard> b) {
        return [@(a.rbPriority) compare:@(b.rbPriority)];
    }];
    rbSortedCards = sorted;
    if (rbCurrentCardIndex >= sorted.count) rbCurrentCardIndex = 0;
    // 0.3.2/0.3.3 presentation rule (approved design):
    //   1 card  -> single card
    //   2+ cards -> CARD STACK: only the front card is laid out, the next one
    //               is drawn behind it with a grabber pill on the shared edge,
    //               and tapping the pill cycles. Vertical swipes stay reserved
    //               for the system Reachability dismiss; nothing is ever tiled.
    BOOL showPeek = (sorted.count >= 2);

    // 0.3.3/0.3.4/0.3.5 card stack, "grabber + depth":
    //   - the card behind is drawn as a BAND ONLY (22pt tall, inset 8pt, radius
    //     +2). Depth is geometry, never an alpha difference;
    //   - 0.3.5: the 1pt light line on the front card's top edge is GONE -- the
    //     band now carries a gradient shadow cast by the front card instead;
    //   - 0.3.5: an 88x15 grabber pill sits ENTIRELY on that band, flush with
    //     its left edge (it used to straddle the seam, centred), and carries a
    //     chevron plus the NEXT card's name.
    // 🔴 0.3.4 field report: at low card opacity the rear card used to be a FULL
    // card painted behind the front one, so it bled through the translucent card
    // and read as a ghost rectangle inside it -- worst with the border at 0,
    // where the card has no silhouette to separate the two planes. A band that
    // never extends behind the front card cannot bleed through at all.
    // The rear card is deliberately NOT a real card view: a real one brings its
    // own rows and hitTest and would steal touches from underneath.
    UIView *rear = nil;
    if (showPeek) {
        rear = [[UIView alloc] initWithFrame:CGRectZero];
        rear.translatesAutoresizingMaskIntoConstraints = NO;
        rear.userInteractionEnabled = NO;
        // SAME alpha as the card on purpose: depth comes from the inset + the
        // offset + the light line, so the stack survives any opacity setting
        // (a "dimmer behind" vanishes exactly when the card gets more lucent).
        rear.backgroundColor = [UIColor colorWithWhite:0.0 alpha:rbStyleOpacity];
        // Top corners only: inside a 14pt window this draws the card's real top
        // arc (flush at the bottom, narrowing towards the top), not a pill.
        rear.layer.cornerRadius = MIN(rbStyleCorner + 2.0, 24.0);
        rear.layer.cornerCurve = kCACornerCurveContinuous;
        rear.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;
        // Follow the user's border setting: a hairline here would be the only
        // outline in a borderless deck and read as a stray line.
        rear.layer.borderWidth = (rbStyleBorder > 0.01) ? 0.5 : 0.0;
        rear.layer.borderColor = [[UIColor whiteColor] colorWithAlphaComponent:0.28].CGColor;
        [container addSubview:rear];
    }

    // Content is centred like ReachPlayer.
    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 12;
    stack.alignment = UIStackViewAlignmentFill;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:stack];
    // 0.2.34: keep the proven centred placement, but let a tall expanded card
    // slide up instead of growing past the home indicator. Center is high (750),
    // so normal content stays exactly where it was; the top/bottom clamps only
    // kick in when the expanded list would overflow.
    // 0.3.2: the 52pt lift that compensated for a tiled second card is gone --
    // a card stack only ever lays out one card.
    NSLayoutConstraint *stackCenterY =
        [stack.centerYAnchor constraintEqualToAnchor:container.centerYAnchor
                                            constant:(rbCardAtBottom ? 140.0 : -110.0)];
    stackCenterY.priority = UILayoutPriorityDefaultHigh; // 750
    // 0.3.1: the top clamp is REQUIRED and its constant is replaced at
    // viewDidAppear with the real safe-area line (see rbUpdateUsableGeometry).
    // 60 is only the pre-measurement placeholder. The bottom clamp drops to 999
    // so a card that still cannot fit overflows the band slightly instead of
    // ever sliding up under the notch.
    rbStackTopConstraint =
        [stack.topAnchor constraintGreaterThanOrEqualToAnchor:container.topAnchor constant:60.0];
    NSLayoutConstraint *stackBottom =
        [stack.bottomAnchor constraintLessThanOrEqualToAnchor:container.bottomAnchor constant:-16];
    stackBottom.priority = 999;
    NSMutableArray<NSLayoutConstraint *> *stackConstraints = [NSMutableArray arrayWithObjects:
        [stack.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:16],
        [stack.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-16],
        stackCenterY,
        stackBottom,
        rbStackTopConstraint,
        nil];
    [NSLayoutConstraint activateConstraints:stackConstraints];
    rbStackView = stack;

    // 0.3.3: the shadow + grabber are created AFTER the stack so they render
    // above the card (a sibling added earlier would be covered by it).
    if (showPeek && rear) {
        // 0.3.5: the 1pt light line is gone. The front card now casts a shadow
        // down onto the rear band, so the two planes separate by shading
        // instead of by a hard hairline that fought the card's own border.
        RBReachDeckShadowView *shade = [[RBReachDeckShadowView alloc] initWithFrame:CGRectZero];
        shade.translatesAutoresizingMaskIntoConstraints = NO;
        shade.layer.cornerRadius = MIN(rbStyleCorner + 2.0, 24.0);
        shade.layer.cornerCurve = kCACornerCurveContinuous;
        shade.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;
        shade.layer.masksToBounds = YES;
        [container addSubview:shade];

        RBReachDeckPeekButton *tap = [[RBReachDeckPeekButton alloc] initWithFrame:CGRectZero];
        tap.translatesAutoresizingMaskIntoConstraints = NO;
        tap.tag = 0x52444234; // 'RDB4': accepted by the hitTest bridge
        tap.userInteractionEnabled = YES;
        tap.accessibilityTraits = UIAccessibilityTraitButton;
        // A handle has to stay tangible: at 20% card opacity "+0.15" would make
        // the pill as lucent as everything else and it stopped reading as a
        // control, so it keeps a floor of 0.55.
        CGFloat pillAlpha = MIN(MAX(rbStyleOpacity + 0.15, 0.55), 1.0);
        tap.backgroundColor = [UIColor colorWithWhite:0.0 alpha:pillAlpha];
        tap.layer.cornerRadius = 7.5;
        tap.layer.cornerCurve = kCACornerCurveContinuous;
        tap.layer.borderWidth = 0.5;
        tap.layer.borderColor = [[UIColor whiteColor] colorWithAlphaComponent:0.45].CGColor;
        [tap addTarget:self action:@selector(rbPeekTouchDown:)
      forControlEvents:UIControlEventTouchDown];
        [tap addTarget:self action:@selector(rbPeekTouchUp:)
      forControlEvents:UIControlEventTouchUpInside];
        [tap addTarget:self action:@selector(rbPeekTouchCancel:)
      forControlEvents:(UIControlEventTouchCancel |
                        UIControlEventTouchUpOutside |
                        UIControlEventTouchDragExit)];
        [container addSubview:tap];
        rbPeekTap = tap;

        UIImageView *chevron = [[UIImageView alloc] initWithImage:
                                [UIImage systemImageNamed:@"chevron.up"]];
        chevron.translatesAutoresizingMaskIntoConstraints = NO;
        chevron.contentMode = UIViewContentModeScaleAspectFit;
        chevron.tintColor = [[UIColor whiteColor] colorWithAlphaComponent:0.60];
        chevron.userInteractionEnabled = NO;
        [tap addSubview:chevron];

        UILabel *name = [[UILabel alloc] init];
        name.translatesAutoresizingMaskIntoConstraints = NO;
        name.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
        name.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.85];
        name.textAlignment = NSTextAlignmentLeft;
        name.lineBreakMode = NSLineBreakByTruncatingTail;
        name.userInteractionEnabled = NO;
        [tap addSubview:name];
        rbPeekLabel = name;

        [NSLayoutConstraint activateConstraints:@[
            // rear band: 8pt inset, kRBPeekOffset higher, and ONLY the band --
            // the 0.5pt tail into the card just hides the anti-aliased seam.
            [rear.leadingAnchor constraintEqualToAnchor:stack.leadingAnchor constant:8],
            [rear.trailingAnchor constraintEqualToAnchor:stack.trailingAnchor constant:-8],
            [rear.topAnchor constraintEqualToAnchor:stack.topAnchor constant:-kRBPeekOffset],
            [rear.heightAnchor constraintEqualToConstant:(kRBPeekOffset + 0.5)],
            // shadow: exactly the band, ending on the front card's top edge so
            // the darkest stop sits against the seam (top corners only, which is
            // why it can be anchored to the band's own box).
            [shade.leadingAnchor constraintEqualToAnchor:rear.leadingAnchor],
            [shade.trailingAnchor constraintEqualToAnchor:rear.trailingAnchor],
            [shade.topAnchor constraintEqualToAnchor:rear.topAnchor],
            [shade.bottomAnchor constraintEqualToAnchor:stack.topAnchor],
            // 0.3.5 grabber: entirely ON the rear band, flush with its left edge.
            // centreY is measured from the seam upwards so the pill can never
            // creep over the front card whatever the band height is. The 14pt
            // inset keeps the pill clear of the band's own top-left arc (radius
            // corner+2 curls ~7pt inwards at this height).
            [tap.leadingAnchor constraintEqualToAnchor:rear.leadingAnchor constant:14],
            [tap.centerYAnchor constraintEqualToAnchor:stack.topAnchor
                                             constant:-(kRBPeekOffset * 0.5)],
            [tap.widthAnchor constraintEqualToConstant:84],
            [tap.heightAnchor constraintEqualToConstant:15],
            [chevron.leadingAnchor constraintEqualToAnchor:tap.leadingAnchor constant:10],
            [chevron.centerYAnchor constraintEqualToAnchor:tap.centerYAnchor],
            [chevron.widthAnchor constraintEqualToConstant:10],
            [chevron.heightAnchor constraintEqualToConstant:10],
            [name.leadingAnchor constraintEqualToAnchor:chevron.trailingAnchor constant:5],
            [name.trailingAnchor constraintEqualToAnchor:tap.trailingAnchor constant:-8],
            [name.centerYAnchor constraintEqualToAnchor:tap.centerYAnchor],
        ]];

        // Self-evidence for the 0.3.5 geometry: these are the exact values the
        // band, the shade and the pill were built with, so a report can be
        // checked without guessing what the sliders were set to.
        RBLog(@"stack rear band h=%.1f inset=8 offset=%.0f alpha=%.2f border=%.1f pill=%.2f pill=lead+14 w=84 h=15 shade=grad",
              (kRBPeekOffset + 0.5), kRBPeekOffset, rbStyleOpacity,
              rear.layer.borderWidth, pillAlpha);

        // 0.4.0: page dots on the right of the band, mirroring the pill on the
        // left. The pill says what the next tap does; the dots say where in the
        // cycle you already are, which the pill alone cannot express once the
        // deck holds three cards. Capped at 5 so a long deck cannot overflow.
        NSUInteger dotCount = MIN(sorted.count, (NSUInteger)5);
        UIStackView *dots = [[UIStackView alloc] init];
        dots.axis = UILayoutConstraintAxisHorizontal;
        dots.spacing = 4.0;
        dots.alignment = UIStackViewAlignmentCenter;
        dots.translatesAutoresizingMaskIntoConstraints = NO;
        dots.userInteractionEnabled = NO;
        for (NSUInteger i = 0; i < dotCount; i++) {
            UIView *dot = [[UIView alloc] initWithFrame:CGRectZero];
            dot.translatesAutoresizingMaskIntoConstraints = NO;
            dot.userInteractionEnabled = NO;
            dot.layer.cornerRadius = 2.0;
            [dot.widthAnchor constraintEqualToConstant:4.0].active = YES;
            [dot.heightAnchor constraintEqualToConstant:4.0].active = YES;
            [dots addArrangedSubview:dot];
        }
        [container addSubview:dots];
        rbPeekDots = dots;
        [NSLayoutConstraint activateConstraints:@[
            [dots.trailingAnchor constraintEqualToAnchor:rear.trailingAnchor constant:-14],
            [dots.centerYAnchor constraintEqualToAnchor:stack.topAnchor
                                           constant:-(kRBPeekOffset * 0.5)],
        ]];

        // Name of the card sitting behind, so the pill says what it switches to.
        NSUInteger nextIdx = (rbCurrentCardIndex + 1) % sorted.count;
        [self rbPeekNameForIndex:nextIdx];
        [self rbUpdatePeekDots];
    } else {
        rbPeekTap = nil;
        rbPeekLabel = nil;
        rbPeekDots = nil;
    }

    for (NSUInteger i = 0; i < sorted.count; i++) {
        id<RBCard> card = sorted[i];
        if ([card respondsToSelector:@selector(rbRefresh)]) [card rbRefresh];
        UIView *v = card.rbView;
        if (!v) continue;
        v.translatesAutoresizingMaskIntoConstraints = NO;
        // Card stack: exactly one card is laid out at a time.
        if (showPeek) v.hidden = (i != rbCurrentCardIndex);
        [stack addArrangedSubview:v];
        RBLog(@"addRBContainer card=%@ h=%.0f hidden=%d",
              [card rbIdentifier], v.frame.size.height, (int)v.hidden);
    }

    rbContainer = container;
    rbHitTestLogCount = 0;
    [topEffect bringSubviewToFront:container];
    RBLog(@"addRBContainer mounted host=%@ container=%@ inWindow=%@ bottom=%d",
          NSStringFromClass([topEffect class]), NSStringFromCGRect(container.frame),
          NSStringFromCGRect([container convertRect:container.bounds toView:nil]), (int)rbCardAtBottom);

    // 0.3.1 diagnostic: measure the usable band immediately (works when we
    // remount while already on screen) and once more after the presentation
    // animation settles, so a report carries real numbers instead of guesses.
    [self rbUpdateUsableGeometry];
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf rbUpdateUsableGeometry];
        RBLog(@"deck layout stack=%@ page=%lu cards=%lu mode=%@",
              NSStringFromCGRect(rbStackView.frame),
              (unsigned long)rbCurrentCardIndex,
              (unsigned long)sorted.count,
              showPeek ? @"peek" : @"single");
    });
}

%new
- (void)rbUpdateUsableGeometry {
    // 0.3.1: the notch / Dynamic Island is a hard physical boundary, and a
    // hardcoded inset (the old +60) is wrong on every other device. Ask the
    // window for the real safe-area line and convert it into container space:
    // the wallpaper host is translated during the reachability animation, and
    // convertRect: bakes that translation in, so the result is correct even
    // though the container itself spans the full 844pt host.
    if (!rbContainer || !rbStackView) return;
    UIView *win = rbContainer.window;
    if (!win) { RBLog(@"deck usable skipped: no window"); return; }

    CGRect containerInWindow = [rbContainer convertRect:rbContainer.bounds toView:nil];
    UIEdgeInsets insets = win.safeAreaInsets;
    // Some overlay windows report a zero safe area even on notched hardware. A
    // zero top inset would put the card straight back under the sensor housing,
    // so fall back to the screen class's real top inset and say so in the log.
    CGFloat safeTop = insets.top;
    if (safeTop <= 0.5) {
        safeTop = (CGRectGetHeight(win.bounds) > 730.0) ? 47.0 : 20.0;
        RBLog(@"deck usable safeTop fallback=%.0f (window reported 0)", safeTop);
    }
    CGFloat notchBottom = safeTop - CGRectGetMinY(containerInWindow);
    // 0.3.3: the rear card sticks out kRBPeekOffset above the front card, so the
    // whole deck starts that much lower and stays below the notch.
    CGFloat peekReserve = (rbSortedCards.count >= 2) ? (kRBPeekOffset + 2.0) : 0.0;
    CGFloat topLimit = notchBottom + 10.0 + peekReserve;
    if (topLimit < 10.0) topLimit = 10.0;
    CGFloat maxTop = CGRectGetHeight(rbContainer.bounds) * 0.45;
    if (topLimit > maxTop) {
        RBLog(@"deck usable clamped topLimit=%.0f -> %.0f", topLimit, maxTop);
        topLimit = maxTop;
    }
    CGFloat bottomLimit = CGRectGetHeight(rbContainer.bounds) - 16.0;
    CGFloat avail = bottomLimit - topLimit;
    RBLog(@"deck usable win=%@ containerInWindow=%@ safeTop=%.0f safeBottom=%.0f "
          @"topLimit=%.0f bottomLimit=%.0f avail=%.0f peek=%.0f stack=%@",
          NSStringFromClass([win class]), NSStringFromCGRect(containerInWindow),
          safeTop, insets.bottom, topLimit, bottomLimit, avail, peekReserve,
          NSStringFromCGRect(rbStackView.frame));
    if (avail < 120.0) { RBLog(@"deck usable bail: avail=%.0f", avail); return; }

    rbStackTopConstraint.constant = topLimit;
    // Tell every card how much room it really has. The privacy card re-windows
    // its expanded row list from this instead of assuming 8 rows fit.
    for (id<RBCard> card in rbSortedCards) {
        if ([card respondsToSelector:@selector(rbSetAvailableHeight:)]) {
            [card rbSetAvailableHeight:avail];
        }
    }
}

%new
- (void)rbPeekNameForIndex:(NSUInteger)index {
    if (index >= rbSortedCards.count) return;
    id<RBCard> card = rbSortedCards[index];
    NSString *title = [card respondsToSelector:@selector(rbRailTitle)] ? card.rbRailTitle : nil;
    if (rbPeekLabel) rbPeekLabel.text = title.length ? title : @"";
    if (rbPeekTap) {
        rbPeekTap.accessibilityLabel = title.length
            ? [NSString stringWithFormat:@"切换到%@", title]
            : @"切换卡片";
    }
}

%new
- (void)rbUpdatePeekDots {
    if (!rbPeekDots) return;
    NSUInteger i = 0;
    NSUInteger on = rbCurrentCardIndex;
    for (UIView *dot in rbPeekDots.arrangedSubviews) {
        CGFloat alpha = (i == on) ? 0.88 : 0.26;
        dot.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:alpha];
        i++;
    }
    RBLog(@"peek dots count=%lu index=%lu",
          (unsigned long)rbPeekDots.arrangedSubviews.count, (unsigned long)on);
}

%new
- (void)rbPeekTouchDown:(RBReachDeckPeekButton *)sender {
    (void)sender;
    // Same rule as the expand footer and the old rail: arm the dismiss
    // suppression on touchDown, because SpringBoard's dismiss callback can
    // arrive before touchUpInside.
    RBPrivacyCancelInteraction();
    RBPrivacyArmInteraction();
    RBLog(@"peek touch down");
}

%new
- (void)rbShowCardAtIndex:(NSUInteger)index {
    if (index >= rbSortedCards.count) return;
    for (NSUInteger i = 0; i < rbSortedCards.count; i++) {
        id<RBCard> card = rbSortedCards[i];
        UIView *v = card.rbView;
        v.hidden = (i != index);
        if (i != index && [card respondsToSelector:@selector(rbWillUnmount)]) {
            [card rbWillUnmount];
        }
    }
    id<RBCard> target = rbSortedCards[index];
    if ([target respondsToSelector:@selector(rbRefresh)]) [target rbRefresh];

    // The card that was hidden behind the sliver "slides out": a short fade +
    // scale so the switch reads as depth rather than a hard cut. The reset is
    // performed WITHOUT animation (the caller already opened one for the height
    // change), and it ends at identity so the card's own hitTest geometry is
    // never left transformed.
    UIView *incoming = target.rbView;
    if (incoming) {
        [UIView performWithoutAnimation:^{
            incoming.alpha = 0.0;
            incoming.transform = CGAffineTransformMakeScale(0.965, 0.965);
        }];
        [UIView animateWithDuration:0.24
                              delay:0
                            options:UIViewAnimationOptionCurveEaseOut |
                                    UIViewAnimationOptionBeginFromCurrentState
                         animations:^{
            incoming.alpha = 1.0;
            incoming.transform = CGAffineTransformIdentity;
        } completion:nil];
    }
    RBLog(@"peek switch index=%lu id=%@",
          (unsigned long)index, [target rbIdentifier]);

    // Keep the grabber pill pointing at the NEW card behind it.
    if (rbSortedCards.count > 1) {
        [self rbPeekNameForIndex:((index + 1) % rbSortedCards.count)];
    }
    [self rbUpdatePeekDots];
}

%new
- (void)rbPeekTouchUp:(RBReachDeckPeekButton *)sender {
    (void)sender;
    if (rbSortedCards.count < 2) {
        RBPrivacyCancelInteraction();
        return;
    }
    NSUInteger next = (rbCurrentCardIndex + 1) % rbSortedCards.count;
    rbCurrentCardIndex = next;
    // Opened around the switch so the deck's height change (a tall expanded
    // privacy card -> the short clipboard card) eases instead of popping.
    [UIView animateWithDuration:0.24 delay:0 options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        [self rbShowCardAtIndex:next];
        // Force the pass inside the block, otherwise the hidden-flag change is
        // laid out after the block closes and the height would pop.
        [rbContainer layoutIfNeeded];
    } completion:nil];

    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(self) strongSelf = weakSelf;
        if (strongSelf) RBPrivacyCancelInteraction();
    });
}

%new
- (void)rbPeekTouchCancel:(RBReachDeckPeekButton *)sender {
    (void)sender;
    RBPrivacyCancelInteraction();
    RBLog(@"peek touch cancel");
}

%end
%end

%group RBReachability

%hook SBReachabilitySettings
- (double)yOffsetFactor { return 0.4; }
- (BOOL)allowOnAllDevices { return YES; }
- (void)setYOffsetFactor:(double)v { %orig(0.4); }
- (void)setAllowOnAllDevices:(BOOL)v { %orig(YES); }
%end

%hook SBReachabilityManager
+ (BOOL)reachabilitySupported { return YES; }
- (BOOL)reachabilityEnabled { return YES; }
- (void)setReachabilityEnabled:(BOOL)v { %orig(YES); }
// 0.2.31 FIX: field log 0.2.30 proved the SYSTEM dismiss gesture calls this
// ~236ms after longpress Began, while the finger is still held on a card row
// and before our menu ever appears. That collapses Reachability under a normal
// long-press. While a row interaction is active, swallow the deactivation so
// the menu can be shown/used. Our OWN launch path clears the flag before it
// calls deactivateReachability, so "open app" still collapses normally.
- (void)deactivateReachability {
    if (RBPrivacyInteractionActive()) {
        NSArray *syms = [NSThread callStackSymbols];
        NSString *top = syms.count > 3
            ? [[syms subarrayWithRange:NSMakeRange(1, 3)] componentsJoinedByString:@" | "]
            : @"(short stack)";
        RBLog(@"deactivate suppressed (row interaction) stack=%@", top);
        return;
    }
    RBLog(@"deactivate reached (system or app launch)");
    %orig;
}
%end

%hook SBApplication
- (BOOL)isReachabilitySupported { return YES; }
- (void)setReachabilitySupported:(BOOL)v { %orig(YES); }
%end

%hook SBAppSwitcherController
- (BOOL)_shouldRespondToReachability { return YES; }
%end

%hook SBIconController
- (BOOL)_shouldRespondToReachability { return YES; }
%end

%hook SpringBoard
- (void)_setReachabilitySupported:(BOOL)v { %orig(YES); }
%end

%end

// ============================================================================
#pragma mark - Sensor activity (passive read, never blocks native indicator)

%group RBSensor

%hook SBSensorActivityDataProvider

- (void)_handleNewDomainData:(id)data {
    // ALWAYS call orig first — never suppress. This keeps the native dot intact.
    %orig;

    // 0.2.3: read both sources. "active" is the ground truth for 正在使用;
    // "all" (active+recent) is the display source so recently used apps can be
    // shown as 最近使用 instead of being silently dropped or mislabelled.
    NSSet *active = nil;
    if ([self respondsToSelector:@selector(activeCameraAndMicrophoneActivityAttributions)]) {
        active = [self activeCameraAndMicrophoneActivityAttributions];
    }
    NSSet *all = nil;
    if ([self respondsToSelector:@selector(activeAndRecentSensorActivityAttributions)]) {
        all = [self activeAndRecentSensorActivityAttributions];
    }
    NSSet *attrs = all ?: active;
    if (privacyCard) [privacyCard ingestAttributions:attrs activeAttributions:active];
    RBLog(@"sensor data active=%lu all=%lu", (unsigned long)active.count, (unsigned long)all.count);
}

%end
%end

// ============================================================================
#pragma mark - Touch bridge

// ReachPlayer hook: SBReachabilityWindow does not route touches in the exposed
// band to _topWallpaperEffectView by itself. Bridge only when the inner hitTest
// lands on one of OUR tagged rows; every other touch keeps the original result,
// so Reachability gestures are untouched.
%group RBHitTest

%hook SBReachabilityWindow

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *candidate = %orig;
    if (!rbTopEffect || !rbContainer) return candidate;

    // 0.2.7 FIX: ReachPlayer's emptyView trick. During the reachability slide the
    // window coordinate system moves (logs show down at y=-178 on our row, then
    // the matching up at y=0 on SBReachabilityBackgroundView). UIKit cancels a
    // gesture when down/up hit different views. Alternate a sticky row so the
    // next hitTest reuses the view chosen on the previous call.
    if (rbStickyRow && [rbStickyRow isDescendantOfView:rbContainer]) {
        UIView *sticky = rbStickyRow;
        rbStickyRow = nil;
        RBLog(@"hitTest reuse sticky=%@", NSStringFromClass([sticky class]));
        return sticky;
    }
    rbStickyRow = nil;

    if (candidate && [candidate isDescendantOfView:rbContainer]) return candidate;

    if (rbHitTestLogCount < 6) {
        RBLog(@"hitTest bridge call point=%@ candidate=%@",
              NSStringFromCGPoint(point), candidate ? NSStringFromClass([candidate class]) : @"nil");
        rbHitTestLogCount++;
    }

    CGPoint local = [rbTopEffect convertPoint:point fromView:self];
    UIView *inner = [rbTopEffect hitTest:local withEvent:event];
    if (inner && [inner isDescendantOfView:rbContainer]) {
        rbStickyRow = inner;
        RBLog(@"hitTest forwarded to %@", NSStringFromClass([inner class]));
        return inner;
    }
    return candidate;
}

%end
%end

// ============================================================================

%ctor {
    @autoreleasepool {
        // SpringBoard-only: the data source lives here; no app-process injection needed.
        NSString *proc = [[[NSProcessInfo processInfo] arguments][0] lastPathComponent];
        if (![proc isEqualToString:@"SpringBoard"]) return;
        RBLogReset();
        RBLog(@"ctor start proc=%@", proc);

        // Data only. RBRebuildCards()/card.rbView are deliberately NOT called here:
        // constructing UIKit objects during dyld initialization is what caused the
        // SpringBoard Safe Mode crash in 0.0.1.
        RBReadPrefs();
        RBLog(@"ctor prefs enabled=%d privacy=%d hideSys=%d bottom=%d", rbEnabled, rbCardPrivacy, rbHideSystemServices, rbCardAtBottom);
        RBLog(@"ctor classes bgVC=%d bgView=%d reachMgr=%d provider=%d",
              (int)(objc_getClass("SBReachabilityBackgroundViewController") != nil),
              (int)(objc_getClass("SBReachabilityBackgroundView") != nil),
              (int)(objc_getClass("SBReachabilityManager") != nil),
              (int)(objc_getClass("SBSensorActivityDataProvider") != nil));
        RBDumpReachabilityClasses();
        RBDumpIvars("SBReachabilityBackgroundView");

        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), NULL,
            (CFNotificationCallback)RBReloadSettings, CFSTR(RB_NOTIFY), NULL,
            CFNotificationSuspensionBehaviorCoalesce);
        RBLog(@"ctor observer registered notify=%s", RB_NOTIFY);

        // Guard every private-class group independently. A class absent on this iOS
        // build must install nothing, never fail at load time.
        if (objc_getClass("SBReachabilityBackgroundViewController")) { %init(RBContainer); RBLog(@"ctor init RBContainer OK"); }
        else RBLog(@"ctor SKIP RBContainer: class missing");

        if (objc_getClass("SBReachabilityWindow")) { %init(RBHitTest); RBLog(@"ctor init RBHitTest OK"); }
        else RBLog(@"ctor SKIP RBHitTest: class missing");

        // Reachability-forcing hooks live in one group; these are long-stable SpringBoard
        // classes (also used unguarded by ReachPlayer), but guard the group entry anyway.
        if (objc_getClass("SBReachabilityManager") ||
            objc_getClass("SBReachabilitySettings") ||
            objc_getClass("SBApplication") ||
            objc_getClass("SBAppSwitcherController") ||
            objc_getClass("SBIconController") ||
            objc_getClass("SpringBoard")) { %init(RBReachability); RBLog(@"ctor init RBReachability OK"); }

        // The privacy provider is the one class measured present on iOS 16.4.1.
        // Guard it too so a hypothetical future rename is inert rather than fatal.
        if (objc_getClass("SBSensorActivityDataProvider")) { %init(RBSensor); RBLog(@"ctor init RBSensor OK"); }

        RBLog(@"ctor done");
    }
}
