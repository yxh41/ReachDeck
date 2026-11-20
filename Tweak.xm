#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <stdarg.h>
#import "RBCardProtocol.h"
#import "RBPrivacyCard.h"

// Diagnostic log (0.0.3): ASCII-only strings so they survive toolchain string
// handling; mirrored to syslog and a plist-dir file the user can send us.
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

// Keep byte-for-byte identical to the prefs side. roothide/rootless fall back to /var/jb.
#define RBPlistPath ([[NSFileManager defaultManager] fileExistsAtPath:@"/var/mobile/Library/Preferences/com.zlhkf.ReachDeck.plist"] ? @"/var/mobile/Library/Preferences/com.zlhkf.ReachDeck.plist" : @"/var/jb/var/mobile/Library/Preferences/com.zlhkf.ReachDeck.plist")

static RBPrivacyCard *privacyCard = nil;
static UIView *rbHostView = nil;          // the _topWallpaperEffectView we mounted into
static UIView *rbContainer = nil;         // our container, recreated on each appear
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

%new
- (void)addRBContainer {
    RBLog(@"addRBContainer enter enabled=%d cards=%lu", rbEnabled, (unsigned long)rbCards.count);
    if (!rbEnabled) { RBLog(@"addRBContainer bail: disabled"); return; } // master switch — hooks stay loaded so re-enabling needs no respring

    // First real presentation. UIApplication is fully initialized here, so this
    // is the earliest safe point to materialize card views.
    if (!rbCards) RBRebuildCards();
    if (rbCards.count == 0) { RBLog(@"addRBContainer bail: no cards"); return; }

    // Reuse the mount point ReachPlayer proved: _topWallpaperEffectView inside the
    // reachability background view. Read the ivar defensively.
    UIView *bg = self.view;
    RBLog(@"addRBContainer bg=%@", NSStringFromClass([bg class]));
    if (![bg isKindOfClass:[UIView class]]) return;

    UIView *topEffect = MSHookIvar<UIView *>(bg, "_topWallpaperEffectView");
    RBLog(@"addRBContainer topEffect=%@", NSStringFromClass([topEffect class]));
    if (!topEffect) { RBLog(@"addRBContainer bail: topEffect nil"); return; }
    rbHostView = topEffect;

    if (rbContainer) { [rbContainer removeFromSuperview]; rbContainer = nil; }

    UIView *container = [[UIView alloc] initWithFrame:topEffect.bounds];
    container.translatesAutoresizingMaskIntoConstraints = NO;
    [topEffect addSubview:container];
    [NSLayoutConstraint activateConstraints:@[
        [container.leadingAnchor constraintEqualToAnchor:topEffect.leadingAnchor],
        [container.trailingAnchor constraintEqualToAnchor:topEffect.trailingAnchor],
        [container.topAnchor constraintEqualToAnchor:topEffect.topAnchor],
        [container.bottomAnchor constraintEqualToAnchor:topEffect.bottomAnchor],
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
    for (id<RBCard> card in sorted) {
        if ([card respondsToSelector:@selector(rbRefresh)]) [card rbRefresh];
        UIView *v = card.rbView;
        RBLog(@"addRBContainer card=%@ view=%@ frame=%@", [card rbIdentifier], NSStringFromClass([v class]), NSStringFromCGRect(v.frame));
        if (!v) continue;
        v.translatesAutoresizingMaskIntoConstraints = NO;
        [stack addArrangedSubview:v];
    }

    rbContainer = container;
    RBLog(@"addRBContainer mounted topEffect.frame=%@", NSStringFromCGRect(topEffect.bounds));
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
        RBLog(@"ctor classes bgVC=%d reachMgr=%d provider=%d",
              (int)(objc_getClass("SBReachabilityBackgroundViewController") != nil),
              (int)(objc_getClass("SBReachabilityManager") != nil),
              (int)(objc_getClass("SBSensorActivityDataProvider") != nil));
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), NULL,
            (CFNotificationCallback)RBReloadSettings, CFSTR(RB_NOTIFY), NULL,
            CFNotificationSuspensionBehaviorCoalesce);

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
            objc_getClass("SpringBoard")) %init(RBReachability);

        // The privacy provider is the one class measured present on iOS 16.4.1.
        // Guard it too so a hypothetical future rename is inert rather than fatal.
        if (objc_getClass("SBSensorActivityDataProvider")) %init(RBSensor);
    }
}
