#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>
#import <stdarg.h>
#import <stdlib.h>
#import <string.h>
#import "RBCardProtocol.h"
#import "RBPrivacyCard.h"
#import "RBClipboardCard.h"

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
static BOOL rbEnabled = YES;
static BOOL rbCardPrivacy = YES;
static BOOL rbCardClipboard = YES;
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
static NSUInteger rbCurrentCardIndex = 0; // 0.3.0: paged deck selection
static NSArray<id<RBCard>> *rbSortedCards = nil;
static NSArray<UIControl *> *rbRailButtons = nil;
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
    RBLog(@"rebuild cards privacy=%d clipboard=%d hideSys=%d bottom=%d count=%lu",
          rbCardPrivacy, rbCardClipboard, rbHideSystemServices, rbCardAtBottom,
          (unsigned long)rbCards.count);
}

// Pure data read — safe from a dylib initializer: Foundation file I/O only,
// no UIKit and no class hooks.
static void RBReadPrefs(void) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:RBPlistPath];
    rbEnabled = d[@"enabled"] ? [d[@"enabled"] boolValue] : YES;
    rbCardPrivacy = d[@"cardPrivacy"] ? [d[@"cardPrivacy"] boolValue] : YES;
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

@class RBReachDeckRailButton;

@interface SBReachabilityBackgroundViewController : UIViewController
- (void)addRBContainer;
- (void)rbRailTouchDown:(RBReachDeckRailButton *)sender;
- (void)rbRailTouchUp:(RBReachDeckRailButton *)sender;
- (void)rbRailTouchCancel:(RBReachDeckRailButton *)sender;
- (void)rbUpdateRailSelection;
- (void)rbUpdateUsableGeometry;
@end

// SBSensorActivityDataProvider — read-only, exact selectors we call.
@interface SBSensorActivityDataProvider : NSObject
- (NSSet *)activeCameraAndMicrophoneActivityAttributions;
- (NSSet *)activeAndRecentSensorActivityAttributions;
@end

// ============================================================================
#pragma mark - Card container

// 0.3.0: one rail item per card. The tag is fixed for hitTest; cardIndex is
// separate because the tag cannot also encode the page number.
@interface RBReachDeckRailButton : UIControl
@property (nonatomic, assign) NSUInteger cardIndex;
@end
@implementation RBReachDeckRailButton
@end

// The container spans the whole Reachability band, but only explicitly tagged
// card rows ('RDB1'), the long-press menu/overlay ('RDB2'), the show-all /
// collapse footer ('RDB3'), the card rail ('RDB4'), and the clipboard card
// root ('RDB5') consume touches. Everything else returns nil so Reachability
// gestures still pass through.
@interface RBReachDeckContainerView : UIView
@end
@implementation RBReachDeckContainerView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (!hit || hit == self) return nil;
    for (UIView *v = hit; v && v != self; v = v.superview) {
        // 'RDB1' row; 'RDB2' menu/overlay; 'RDB3' expand footer;
        // 'RDB4' card rail item; 'RDB5' clipboard card root.
        if (v.tag == 0x52444231 || v.tag == 0x52444232 ||
            v.tag == 0x52444233 || v.tag == 0x52444234 ||
            v.tag == 0x52444235) return hit;
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
    rbRailButtons = nil;
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
    // 0.3.0 paging rule (the approved design):
    //   1 card  -> single card, no rail
    //   2 cards -> both stacked, no rail (there is nothing to switch between)
    //   3+      -> one card at a time, vertical rail on the deck's right edge
    BOOL showAllCards = (sorted.count <= 2);
    BOOL hasRail = (sorted.count > 2);

    // 0.3.0: vertical card rail on the deck's right edge (NOT the screen edge).
    // It is tap-only; vertical swipes stay reserved for Reachability dismissal.
    UIStackView *rail = nil;
    NSMutableArray<UIControl *> *railButtons = [NSMutableArray array];
    if (hasRail) {
        rail = [[UIStackView alloc] init];
        rail.axis = UILayoutConstraintAxisVertical;
        rail.spacing = 8;
        rail.alignment = UIStackViewAlignmentCenter;
        rail.translatesAutoresizingMaskIntoConstraints = NO;
        [container addSubview:rail];

        for (NSUInteger i = 0; i < sorted.count; i++) {
            id<RBCard> card = sorted[i];
            RBReachDeckRailButton *button = [[RBReachDeckRailButton alloc] initWithFrame:CGRectZero];
            button.cardIndex = i;
            button.tag = 0x52444234; // 'RDB4': accepted by the hitTest bridge
            button.translatesAutoresizingMaskIntoConstraints = NO;
            button.layer.cornerRadius = 13;
            button.userInteractionEnabled = YES;
            button.accessibilityTraits = UIAccessibilityTraitButton;
            if ([card respondsToSelector:@selector(rbRailTitle)]) {
                button.accessibilityLabel = card.rbRailTitle;
            }
            [button addTarget:self action:@selector(rbRailTouchDown:)
             forControlEvents:UIControlEventTouchDown];
            [button addTarget:self action:@selector(rbRailTouchUp:)
             forControlEvents:UIControlEventTouchUpInside];
            [button addTarget:self action:@selector(rbRailTouchCancel:)
             forControlEvents:(UIControlEventTouchCancel |
                             UIControlEventTouchUpOutside |
                             UIControlEventTouchDragExit)];

            NSString *symbol = @"square.grid.2x2.fill";
            if ([card respondsToSelector:@selector(rbRailImageName)] && card.rbRailImageName.length) {
                symbol = card.rbRailImageName;
            }
            UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:symbol]];
            icon.translatesAutoresizingMaskIntoConstraints = NO;
            icon.contentMode = UIViewContentModeScaleAspectFit;
            icon.userInteractionEnabled = NO;
            [button addSubview:icon];
            [NSLayoutConstraint activateConstraints:@[
                [button.widthAnchor constraintEqualToConstant:26],
                [button.heightAnchor constraintEqualToConstant:26],
                [icon.centerXAnchor constraintEqualToAnchor:button.centerXAnchor],
                [icon.centerYAnchor constraintEqualToAnchor:button.centerYAnchor],
                [icon.widthAnchor constraintEqualToConstant:14],
                [icon.heightAnchor constraintEqualToConstant:14],
            ]];
            [rail addArrangedSubview:button];
            [railButtons addObject:button];
        }
        rbRailButtons = [railButtons copy];
    } else {
        rbRailButtons = nil;
    }

    // Content is centred like ReachPlayer, but the card area now leaves room for
    // the rail when more than one card exists.
    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 12;
    stack.alignment = UIStackViewAlignmentFill;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:stack];
    // 0.2.34: keep the proven centred placement, but let a tall expanded card
    // slide up instead of growing past the home indicator. Center is high (750),
    // so normal content stays exactly where it was; the required bottom/top
    // clamps only kick in when the expanded list would overflow.
    // 0.3.0: with two cards stacked, keep the SAME bottom edge as a single card
    // so the deck grows upward into free space instead of covering the home
    // indicator (52pt ~= half of the clipboard card's height).
    CGFloat deckLift = (showAllCards && sorted.count > 1) ? 52.0 : 0.0;
    NSLayoutConstraint *stackCenterY =
        [stack.centerYAnchor constraintEqualToAnchor:container.centerYAnchor
                                            constant:(rbCardAtBottom ? 140.0 : -110.0) - deckLift];
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
        stackCenterY,
        stackBottom,
        rbStackTopConstraint,
        nil];
    rbStackView = stack;
    if (hasRail) {
        [stackConstraints addObject:[stack.trailingAnchor constraintEqualToAnchor:rail.leadingAnchor constant:-8]];
        [stackConstraints addObject:[rail.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-8]];
        [stackConstraints addObject:[rail.centerYAnchor constraintEqualToAnchor:stack.centerYAnchor]];
        [stackConstraints addObject:[rail.widthAnchor constraintEqualToConstant:28]];
    } else {
        [stackConstraints addObject:[stack.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-16]];
    }
    [NSLayoutConstraint activateConstraints:stackConstraints];

    for (NSUInteger i = 0; i < sorted.count; i++) {
        id<RBCard> card = sorted[i];
        if ([card respondsToSelector:@selector(rbRefresh)]) [card rbRefresh];
        UIView *v = card.rbView;
        if (!v) continue;
        v.translatesAutoresizingMaskIntoConstraints = NO;
        // Paged mode shows one card; stacked mode shows every card at once.
        if (hasRail) v.hidden = (i != rbCurrentCardIndex);
        [stack addArrangedSubview:v];
        RBLog(@"addRBContainer card=%@ h=%.0f hidden=%d",
              [card rbIdentifier], v.frame.size.height, (int)v.hidden);
    }
    [self rbUpdateRailSelection];

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
              showAllCards ? @"stack" : (hasRail ? @"page" : @"single"));
    });
}

%new
- (void)rbUpdateRailSelection {
    for (NSUInteger i = 0; i < rbRailButtons.count; i++) {
        UIControl *button = rbRailButtons[i];
        BOOL active = (i == rbCurrentCardIndex);
        button.backgroundColor = active
            ? [[UIColor whiteColor] colorWithAlphaComponent:0.18]
            : [UIColor clearColor];
        for (UIView *sub in button.subviews) {
            if ([sub isKindOfClass:[UIImageView class]]) {
                ((UIImageView *)sub).tintColor =
                    [[UIColor whiteColor] colorWithAlphaComponent:(active ? 0.95 : 0.45)];
            }
        }
    }
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
    CGFloat topLimit = notchBottom + 10.0;
    if (topLimit < 10.0) topLimit = 10.0;
    CGFloat maxTop = CGRectGetHeight(rbContainer.bounds) * 0.45;
    if (topLimit > maxTop) {
        RBLog(@"deck usable clamped topLimit=%.0f -> %.0f", topLimit, maxTop);
        topLimit = maxTop;
    }
    CGFloat bottomLimit = CGRectGetHeight(rbContainer.bounds) - 16.0;
    CGFloat avail = bottomLimit - topLimit;
    // Stacked mode (2 cards) shows both at once, so a card that CANNOT resize
    // gets its height reserved first and the variable-height card only receives
    // what is left over. Unknown height falls back to the clipboard card's
    // measured ~100pt + stack spacing.
    CGFloat reserved = 0.0;
    if (rbSortedCards.count == 2) {
        for (id<RBCard> other in rbSortedCards) {
            if (![other respondsToSelector:@selector(rbSetAvailableHeight:)]) {
                CGFloat h = CGRectGetHeight(other.rbView.frame);
                reserved = (h > 1.0 ? h : 100.0) + 12.0;
                break;
            }
        }
    }
    RBLog(@"deck usable win=%@ containerInWindow=%@ safeTop=%.0f safeBottom=%.0f "
          @"topLimit=%.0f bottomLimit=%.0f avail=%.0f reserved=%.0f stack=%@",
          NSStringFromClass([win class]), NSStringFromCGRect(containerInWindow),
          safeTop, insets.bottom, topLimit, bottomLimit, avail, reserved,
          NSStringFromCGRect(rbStackView.frame));
    if (avail < 120.0) { RBLog(@"deck usable bail: avail=%.0f", avail); return; }

    rbStackTopConstraint.constant = topLimit;
    // Tell every card how much room it really has. The privacy card re-windows
    // its expanded row list from this instead of assuming 8 rows fit.
    for (id<RBCard> card in rbSortedCards) {
        if ([card respondsToSelector:@selector(rbSetAvailableHeight:)]) {
            [card rbSetAvailableHeight:(avail - reserved)];
        }
    }
}

%new
- (void)rbRailTouchDown:(RBReachDeckRailButton *)sender {
    // Close any privacy menu first, then arm suppression before SpringBoard's
    // dismiss gesture sees this touch (same rule as the expand footer).
    RBPrivacyCancelInteraction();
    RBPrivacyArmInteraction();
    RBLog(@"rail touch down index=%lu", (unsigned long)sender.cardIndex);
}

%new
- (void)rbRailTouchUp:(RBReachDeckRailButton *)sender {
    NSUInteger idx = sender.cardIndex;
    if (idx >= rbSortedCards.count) {
        RBPrivacyCancelInteraction();
        return;
    }
    if (rbSortedCards.count <= 2) {
        // Stacked mode (<=2 cards) has no rail; nothing to page.
        RBPrivacyCancelInteraction();
        RBLog(@"rail switch ignored: stacked mode count=%lu",
              (unsigned long)rbSortedCards.count);
        return;
    }
    rbCurrentCardIndex = idx;
    for (NSUInteger i = 0; i < rbSortedCards.count; i++) {
        id<RBCard> card = rbSortedCards[i];
        UIView *v = card.rbView;
        v.hidden = (i != idx);
        if (i != idx && [card respondsToSelector:@selector(rbWillUnmount)]) {
            [card rbWillUnmount];
        }
    }
    [self rbUpdateRailSelection];
    id<RBCard> target = rbSortedCards[idx];
    if ([target respondsToSelector:@selector(rbRefresh)]) [target rbRefresh];
    RBLog(@"rail switch index=%lu id=%@",
          (unsigned long)idx, [target rbIdentifier]);

    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(self) strongSelf = weakSelf;
        if (strongSelf) RBPrivacyCancelInteraction();
    });
}

%new
- (void)rbRailTouchCancel:(RBReachDeckRailButton *)sender {
    (void)sender;
    RBPrivacyCancelInteraction();
    RBLog(@"rail touch cancel");
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
