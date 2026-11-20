#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <stdarg.h>
#import <stdlib.h>
#import <string.h>
#import "RBCardProtocol.h"
#import "RBPrivacyCard.h"

// Diagnostic log (0.0.3+): ASCII-only strings so they survive toolchain string
// handling; mirrored to syslog and a plist-dir file the user can send us.
// Foundation-only — never reaches UIKit, so it stays safe inside %ctor.
static NSString *RBLogPath(void) {
    NSString *a = @"/var/mobile/Library/Preferences/com.zlhkf.ReachDeck.debug.log";
    NSString *b = @"/var/jb/var/mobile/Library/Preferences/com.zlhkf.ReachDeck.debug.log";
    return [[NSFileManager defaultManager] fileExistsAtPath:@"/var/mobile/Library/Preferences"] ? a : b;
}
static void RBLog(NSString *fmt, ...) {
    va_list args; va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
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
static UIView *rbHostView = nil;          // the view we mounted into
static UIView *rbContainer = nil;         // our container, recreated on each appear
static UIView *rbCardView = nil;          // top card view, for post-layout diagnostics
static BOOL rbEnabled = YES;
static BOOL rbCardPrivacy = YES;
static BOOL rbHideSystemServices = NO;
static NSArray<id<RBCard>> *rbCards = nil;

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
    rbCards = [cards copy];
    RBLog(@"rebuild cards privacy=%d hideSys=%d count=%lu", rbCardPrivacy, rbHideSystemServices, (unsigned long)rbCards.count);
}

// Pure data read — safe from a dylib initializer: Foundation file I/O only,
// no UIKit and no class hooks.
static void RBReadPrefs(void) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:RBPlistPath];
    rbEnabled = d[@"enabled"] ? [d[@"enabled"] boolValue] : YES;
    rbCardPrivacy = d[@"cardPrivacy"] ? [d[@"cardPrivacy"] boolValue] : YES;
    rbHideSystemServices = d[@"hideSystemServices"] ? [d[@"hideSystemServices"] boolValue] : NO;
}

// Darwin callback. The Reachability view only exists while the window is up, so
// "immediate" means: next present builds from the new config. No respring needed.
// We never reach into the live view here — finding the reachability controller from
// a scene graph is fragile, and the next viewWillAppear already handles remounting.
static void RBReloadSettings(void) {
    RBReadPrefs();
    RBRebuildCards();
}

// ---- Private SpringBoard interfaces ----
@interface SBReachabilityManager : NSObject
+ (id)sharedInstance;
- (void)toggleReachability;
@end

@interface SBReachabilitySettings : NSObject
- (double)yOffsetFactor;
- (BOOL)allowOnAllDevices;
@end

@interface SBReachabilityBackgroundView : UIView
@end

@interface SBReachabilityBackgroundViewController : UIViewController
- (void)addRBContainer;
@end

// SBSensorActivityDataProvider — present on iOS 16.4.1. We only *read* it.
// Declared with the exact selectors we call; no ivar access (Logos forward-decl rule).
@interface SBSensorActivityDataProvider : NSObject
- (NSSet *)activeCameraAndMicrophoneActivityAttributions;
- (NSSet *)activeAndRecentSensorActivityAttributions;
@end

// ============================================================================
#pragma mark - Card container

%group RBContainer

%hook SBReachabilityBackgroundViewController

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    RBLog(@"viewWillAppear fired");
    [self addRBContainer];
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    // Secondary trigger: never rely on a single presentation callback. If the
    // container is still absent here, mount now. Idempotent by construction.
    if (!rbContainer) {
        RBLog(@"viewDidAppear fired, mounting (no container yet)");
        [self addRBContainer];
    }
}

- (void)viewWillDisappear:(BOOL)animated {
    %orig;
    // Tear the overlay down with the host. A container left behind on SpringBoard's
    // window would be a full-screen transparent view pinned over everything.
    if (rbContainer) {
        RBLog(@"viewWillDisappear -> remove container");
        [rbContainer removeFromSuperview];
        rbContainer = nil;
        rbCardView = nil;
    }
}

%new
- (void)addRBContainer {
    RBLog(@"addRBContainer enter enabled=%d cards=%lu", rbEnabled, (unsigned long)rbCards.count);
    if (!rbEnabled) { RBLog(@"addRBContainer bail: disabled"); return; } // master switch — hooks stay loaded so re-enabling needs no respring

    // First real presentation. UIApplication is fully initialized here, so this
    // is the earliest safe point to materialize card views.
    if (!rbCards) RBRebuildCards();
    if (rbCards.count == 0) { RBLog(@"addRBContainer bail: no cards"); return; }

    UIView *bg = self.view;
    if (![bg isKindOfClass:[UIView class]]) { RBLog(@"addRBContainer bail: no bg view"); return; }

    UIWindow *win = bg.window;
    UIView *topEffect = MSHookIvar<UIView *>(bg, "_topWallpaperEffectView");
    UIView *wallContainer = MSHookIvar<UIView *>(bg, "_wallpaperContainerView");
    RBLog(@"addRBContainer bg=%@ frame=%@ alpha=%.2f hidden=%d super=%@ win=%@",
          NSStringFromClass([bg class]), NSStringFromCGRect(bg.frame), bg.alpha, (int)bg.hidden,
          NSStringFromClass([bg.superview class]), NSStringFromClass([win class]));
    RBLog(@"addRBContainer topEffect=%@ frame=%@ alpha=%.2f hidden=%d win=%d wallContainer=%@",
          NSStringFromClass([topEffect class]),
          topEffect ? NSStringFromCGRect(topEffect.frame) : @"(nil)",
          topEffect ? topEffect.alpha : -1.0,
          topEffect ? (int)topEffect.hidden : -1,
          topEffect ? (int)(topEffect.window != nil) : -1,
          NSStringFromClass([wallContainer class]));
    for (UIView *sub in bg.subviews) {
        RBLog(@"  bgsub %@ alpha=%.2f hidden=%d frame=%@",
              NSStringFromClass([sub class]), sub.alpha, (int)sub.hidden, NSStringFromCGRect(sub.frame));
    }

    if (rbContainer) { [rbContainer removeFromSuperview]; rbContainer = nil; }

    // MOUNT CHANGE (0.0.7): mount on the controller's own view and force it above
    // every sibling. 0.0.4/0.0.5 mounted into _topWallpaperEffectView (ReachPlayer's
    // proven target) and produced a correctly sized 358x80 card that was still not
    // visible — the classic symptom of host-internal layers drawing over user
    // subviews. bg + bringSubviewToFront removes that variable entirely.
    UIView *host = bg;
    rbHostView = host;
    RBLog(@"addRBContainer host=%@", NSStringFromClass([host class]));

    UIView *container = [[UIView alloc] initWithFrame:host.bounds];
    container.translatesAutoresizingMaskIntoConstraints = NO;
    container.backgroundColor = [UIColor clearColor];
    // The overlay must never swallow reachability's own gestures.
    container.userInteractionEnabled = NO;
    [host addSubview:container];
    [host bringSubviewToFront:container];
    [NSLayoutConstraint activateConstraints:@[
        [container.leadingAnchor constraintEqualToAnchor:host.leadingAnchor],
        [container.trailingAnchor constraintEqualToAnchor:host.trailingAnchor],
        [container.topAnchor constraintEqualToAnchor:host.topAnchor],
        [container.bottomAnchor constraintEqualToAnchor:host.bottomAnchor],
    ]];

    // Stack the enabled cards vertically; each card owns its internal layout.
    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 12;
    stack.alignment = UIStackViewAlignmentFill;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:16],
        [stack.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-16],
        [stack.topAnchor constraintEqualToAnchor:container.topAnchor constant:24],
        [stack.bottomAnchor constraintLessThanOrEqualToAnchor:container.bottomAnchor constant:-24],
    ]];

    NSArray<id<RBCard>> *sorted = [rbCards sortedArrayUsingComparator:^NSComparisonResult(id<RBCard> a, id<RBCard> b) {
        return [@(a.rbPriority) compare:@(b.rbPriority)];
    }];
    rbCardView = nil;
    for (id<RBCard> card in sorted) {
        if ([card respondsToSelector:@selector(rbRefresh)]) [card rbRefresh];
        UIView *v = card.rbView;
        RBLog(@"addRBContainer card=%@ view=%@ frame=%@",
              [card rbIdentifier], NSStringFromClass([v class]), NSStringFromCGRect(v.frame));
        if (!v) continue;
        v.translatesAutoresizingMaskIntoConstraints = NO;
        [stack addArrangedSubview:v];
        if (!rbCardView) rbCardView = v;
    }

    rbContainer = container;
    RBLog(@"addRBContainer mounted host=%@ bounds=%@", NSStringFromClass([host class]), NSStringFromCGRect(host.bounds));

    // POST-LAYOUT PROOF (0.0.7): one runloop later report real on-screen geometry.
    // "container.window != nil" plus a non-empty rect in window coordinates is the
    // only evidence that the card is actually drawn, so this is logged, not assumed.
    __weak UIView *wContainer = container;
    __weak UIView *wBg = bg;
    __weak UIView *wCard = rbCardView;
    UIWindow *wWin = win;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIView *c = wContainer, *b = wBg, *cv = wCard;
        if (!c) { RBLog(@"postMount container gone"); return; }
        [b bringSubviewToFront:c];
        RBLog(@"postMount container win=%d frame=%@ inWindow=%@ alpha=%.2f hidden=%d super=%@",
              (int)(c.window != nil), NSStringFromCGRect(c.frame),
              NSStringFromCGRect([c convertRect:c.bounds toView:nil]),
              c.alpha, (int)c.hidden, NSStringFromClass([c.superview class]));
        if (!c.window && wWin) {
            RBLog(@"postMount container not in a window -> remount on window %@", NSStringFromClass([wWin class]));
            [c removeFromSuperview];
            c.translatesAutoresizingMaskIntoConstraints = NO;
            [wWin addSubview:c];
            [wWin bringSubviewToFront:c];
            [NSLayoutConstraint activateConstraints:@[
                [c.leadingAnchor constraintEqualToAnchor:wWin.leadingAnchor],
                [c.trailingAnchor constraintEqualToAnchor:wWin.trailingAnchor],
                [c.topAnchor constraintEqualToAnchor:wWin.topAnchor],
                [c.bottomAnchor constraintEqualToAnchor:wWin.bottomAnchor],
            ]];
        }
        if (cv) {
            UIView *stackView = cv.superview;
            RBLog(@"postMount card frame=%@ inWindow=%@ alpha=%.2f hidden=%d window=%d",
                  NSStringFromCGRect(cv.frame),
                  NSStringFromCGRect([cv convertRect:cv.bounds toView:nil]),
                  cv.alpha, (int)cv.hidden, (int)(cv.window != nil));
            RBLog(@"postMount card stack=%@ stackFrame=%@ cardBg=%@",
                  NSStringFromClass([stackView class]), NSStringFromCGRect(stackView.frame), cv.backgroundColor);
        }
    });
}

%end
%end

// ============================================================================
#pragma mark - Reachability forcing (from ReachPlayer, proven on 13-16.4)

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

    NSSet *attrs = nil;
    if ([self respondsToSelector:@selector(activeCameraAndMicrophoneActivityAttributions)]) {
        attrs = [self activeCameraAndMicrophoneActivityAttributions];
    }
    if (!attrs && [self respondsToSelector:@selector(activeAndRecentSensorActivityAttributions)]) {
        attrs = [self activeAndRecentSensorActivityAttributions];
    }
    if (privacyCard) [privacyCard ingestAttributions:attrs];
    RBLog(@"sensor data attrs=%lu", (unsigned long)attrs.count);
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
        RBLog(@"ctor prefs enabled=%d privacy=%d hideSys=%d", rbEnabled, rbCardPrivacy, rbHideSystemServices);
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
