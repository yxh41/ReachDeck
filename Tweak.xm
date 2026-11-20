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
void RBLog(NSString *fmt, ...) {
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
static BOOL rbEnabled = YES;
static BOOL rbCardPrivacy = YES;
static BOOL rbHideSystemServices = NO;
static BOOL rbCardAtBottom = YES;         // 0.2.1: derived from cardAtTop (default off => bottom)
static NSArray<id<RBCard>> *rbCards = nil;
static UIView *rbContainer = nil;        // container mounted inside _topWallpaperEffectView

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
    RBLog(@"rebuild cards privacy=%d hideSys=%d bottom=%d count=%lu", rbCardPrivacy, rbHideSystemServices, rbCardAtBottom, (unsigned long)rbCards.count);
}

// Pure data read — safe from a dylib initializer: Foundation file I/O only,
// no UIKit and no class hooks.
static void RBReadPrefs(void) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:RBPlistPath];
    rbEnabled = d[@"enabled"] ? [d[@"enabled"] boolValue] : YES;
    rbCardPrivacy = d[@"cardPrivacy"] ? [d[@"cardPrivacy"] boolValue] : YES;
    rbHideSystemServices = d[@"hideSystemServices"] ? [d[@"hideSystemServices"] boolValue] : NO;
    // 0.2.1: the UI switch is "cardAtTop" (off = bottom, the visible band on this
    // device). Honour the old cardAtBottom key too for users upgrading from 0.1.x.
    rbCardAtBottom = d[@"cardAtTop"] ? ![d[@"cardAtTop"] boolValue]
                   : (d[@"cardAtBottom"] ? [d[@"cardAtBottom"] boolValue] : YES);
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
- (void)_notifyObserversReachabilityYOffsetDidChange;
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

// SBSensorActivityDataProvider — read-only, exact selectors we call.
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
}

- (void)viewWillDisappear:(BOOL)animated {
    %orig;
    rbLiveController = nil;
    rbTopEffect = nil;
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

    if (rbContainer) { [rbContainer removeFromSuperview]; rbContainer = nil; }

    // ReachPlayer: frame = host.bounds + four equal edge constraints.
    UIView *container = [[UIView alloc] initWithFrame:topEffect.bounds];
    container.backgroundColor = [UIColor clearColor];
    container.userInteractionEnabled = NO;   // never swallow reachability gestures
    [topEffect addSubview:container];
    container.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [container.topAnchor constraintEqualToAnchor:topEffect.topAnchor],
        [container.bottomAnchor constraintEqualToAnchor:topEffect.bottomAnchor],
        [container.leadingAnchor constraintEqualToAnchor:topEffect.leadingAnchor],
        [container.trailingAnchor constraintEqualToAnchor:topEffect.trailingAnchor],
    ]];

    // Content is centred like ReachPlayer (centerX/centerY), not pinned to an edge
    // of a view the system keeps moving around.
    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 12;
    stack.alignment = UIStackViewAlignmentFill;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.centerXAnchor constraintEqualToAnchor:container.centerXAnchor],
        [stack.centerYAnchor constraintEqualToAnchor:container.centerYAnchor constant:(rbCardAtBottom ? 140.0 : -110.0)],
        [stack.widthAnchor constraintEqualToAnchor:container.widthAnchor constant:-32],
    ]];

    NSArray<id<RBCard>> *sorted = [rbCards sortedArrayUsingComparator:^NSComparisonResult(id<RBCard> a, id<RBCard> b) {
        return [@(a.rbPriority) compare:@(b.rbPriority)];
    }];
    for (id<RBCard> card in sorted) {
        if ([card respondsToSelector:@selector(rbRefresh)]) [card rbRefresh];
        UIView *v = card.rbView;
        if (!v) continue;
        v.translatesAutoresizingMaskIntoConstraints = NO;
        [stack addArrangedSubview:v];
        RBLog(@"addRBContainer card=%@ frame=%@", [card rbIdentifier], NSStringFromCGRect(v.frame));
    }

    rbContainer = container;
    [topEffect bringSubviewToFront:container];
    RBLog(@"addRBContainer mounted host=%@ container=%@ inWindow=%@ bottom=%d",
          NSStringFromClass([topEffect class]), NSStringFromCGRect(container.frame),
          NSStringFromCGRect([container convertRect:container.bounds toView:nil]), (int)rbCardAtBottom);
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
