#import "RBPrivacyCard.h"
#import <objc/runtime.h>
#import <objc/message.h>   // objc_msgSend for SBWorkspace openApplicationWithBundleID:

// Private but stable SpringBoard-side launcher; guarded by objc_getClass and
// respondsToSelector: before use.
@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (BOOL)openApplicationWithBundleID:(NSString *)bundleID;
@end

static char kRBRowAssociationKey;
static char kRBDurationKeyKey;                 // 0.2.27: rowKey on the duration label
static char kRBLongPressRowKey;                // 0.2.29: full row dict on the long-press recognizer
static char kRBMenuContextKey;                 // 0.2.29: row dict on the popup menu
static NSInteger const kRBMenuTag = 0x52444232; // 'RDB2': menu/overlay allowed by hitTest bridge
static NSInteger rbPulseCount = 0;              // 0.2.17 diagnostic pulse counter
static NSTimer *rbPulseTimer = nil;            // keep only one pulse series alive
static NSInteger rbDurationShowLogged = 0;      // 0.2.28: log first few labels for self-proof
static BOOL rbPrivacyInteractionActive = NO;    // 0.2.31: read by Tweak.xm deactivate hook
static RBPrivacyCard *rbActivePrivacyCard = nil; // 0.2.31: for cross-process cancel on collapse

// ---- Private SpringBoard interfaces (runtime-verified from iOS 17/18 headers) ----
// We deliberately do NOT declare a hardcoded sensor enum: its numeric values are not
// stable across iOS versions. Instead we read the semantic property and fall back to
// the attribution's description. This is the "don't guess the API" rule in code form.
// NOTE: do NOT use conformsToProtocol with a locally declared protocol here:
// SBSensorActivityAttribution never declares conformance to it (0.2.1 fix).


@interface RBPrivacyCard ()
@property (nonatomic, strong) UIView *view;
@property (nonatomic, strong) UIStackView *contentStack;
@property (nonatomic, strong) UIStackView *rowsStack;
@property (nonatomic, strong) UILabel *emptyLabel;
@property (nonatomic, strong) NSArray<NSDictionary *> *rows; // visible rows after merge/sort/cap
@property (nonatomic, assign) BOOL hideSystemServices;
@property (nonatomic, strong) NSSet *lastAttributions;
@property (nonatomic, strong) NSSet *lastActiveAttributions;
@property (nonatomic, assign) NSUInteger hiddenCount;
@property (nonatomic, copy) NSString *lastRenderSignature;
// 0.2.19 style
@property (nonatomic, assign) CGFloat styleOpacity;
@property (nonatomic, assign) CGFloat styleCorner;
@property (nonatomic, assign) CGFloat styleBorder;
@property (nonatomic, assign) BOOL styleCompact;
// 0.2.25: transient "copied" toast, owned by the card root view.
@property (nonatomic, strong) UILabel *toastLabel;
// 0.2.27/0.2.28: sensor usage duration. No timestamp on
// SBSensorActivityAttribution, so record first-seen time per bundle and tick
// the labels every second.
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSDate *> *activeSince;
@property (nonatomic, strong) NSTimer *durationTimer;
// 0.2.29: long-press action menu. It lives on the card's HOST (not the clipped
// card root) so it is never cut off and never rebuilt by renderRows.
@property (nonatomic, strong) UIView *menuView;
@property (nonatomic, strong) UIView *menuOverlay;
@property (nonatomic, strong) NSMutableSet<NSString *> *sessionHiddenBundles;
- (void)performLaunchForBundle:(NSString *)bundle;
- (void)rbCollapseAndLaunchBundle:(NSString *)bundle;
- (void)rbLaunchPulse:(NSTimer *)timer;
- (void)rbShowCopiedToast:(NSString *)bundle;
- (void)rbTickDurations:(NSTimer *)timer;
- (NSString *)rbDurationTextForBundle:(NSString *)bundle;
- (void)rbShowRowMenu:(UILongPressGestureRecognizer *)gesture;
- (void)rbDismissRowMenu:(id)sender;
- (void)rbMenuTapped:(UIButton *)button;
@end

@implementation RBPrivacyCard

@synthesize rbPriority = _rbPriority;
@synthesize rbIdentifier = _rbIdentifier;
@synthesize rbWantsPin = _rbWantsPin;
// rbView is backed by `self.view` via the custom getter below; synthesizing an
// ivar here triggers -Werror,-Wunused-property-ivar under -Wall.

- (instancetype)init {
    self = [super init];
    if (self) {
        _rbPriority = 100;
        _rbIdentifier = @"privacy";
        _rbWantsPin = YES;
        _hideSystemServices = NO;
        // 0.2.19 defaults match the pre-style look, so upgrading changes nothing.
        _styleOpacity = 0.72;
        _styleCorner = 16;
        _styleBorder = 1;
        _styleCompact = NO;
        _rows = @[];
        _activeSince = [NSMutableDictionary dictionary];
        _sessionHiddenBundles = [NSMutableSet set];
        rbActivePrivacyCard = self;
        // SAFE MODE FIX (0.0.2): never touch UIKit here. A card can be created
        // while dyld is still running tweak initializers, before UIApplication is
        // initialized. UIView / Auto Layout calls at that point throw an
        // uncaught NSException from UIKitCore and abort SpringBoard. Keep this
        // object state-only; the UI is built lazily from -rbView, which is only
        // reached after SBReachabilityBackgroundViewController viewWillAppear.
    }
    return self;
}

- (void)dealloc {
    // 0.2.27: repeating NSTimer retains its target; break the cycle so the card
    // can go away when the tweak rebuilds cards.
    [self.durationTimer invalidate];
    self.durationTimer = nil;
    if (rbActivePrivacyCard == self) rbActivePrivacyCard = nil;
}

// 0.2.31 exported state, read from Tweak.xm's -deactivateReachability hook.
// C linkage (see header) so the ObjC++ tweak can call into this ObjC file.
BOOL RBPrivacyInteractionActive(void) { return rbPrivacyInteractionActive; }
void RBPrivacyCancelInteraction(void) {
    rbPrivacyInteractionActive = NO;
    [rbActivePrivacyCard rbDismissRowMenu:nil];
}

#pragma mark - RBCard

- (UIView *)rbView {
    // Lazy UI construction: first real access happens inside addRBContainer,
    // i.e. on the main thread with UIApplication fully up.
    if (!self.view) {
        [self buildView];
        [self renderRows]; // reflect sensor data ingested before the UI existed
        // 0.2.27: start the 1s duration ticker once the UI exists. Repeating
        // timer retains self; invalidate on style rebuild / dealloc to avoid a
        // dangling ticker (ARC-safe, unlike the 0.2.17 block attempt).
        if (!self.durationTimer) {
            // target/selector (not block) avoids -Warc-retain-cycles; a repeating
            // timer legitimately retains its target, invalidated in dealloc.
            self.durationTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                                  target:self
                                                                selector:@selector(rbTickDurations:)
                                                                userInfo:nil
                                                                 repeats:YES];
            // Reachability/drag can put SpringBoard's main runloop in tracking
            // mode. Common modes keeps the label ticking there too.
            [[NSRunLoop mainRunLoop] addTimer:self.durationTimer forMode:NSRunLoopCommonModes];
        }
    }
    return self.view;
}
- (NSInteger)rbPriority { return _rbPriority; }
- (NSString *)rbIdentifier { return _rbIdentifier; }
- (BOOL)rbWantsPin { return _rbWantsPin; }

- (void)rbRefresh {
    // Container calls this on appear. The provider push (ingestAttributions:) is the
    // real source of truth; refresh just re-renders whatever we last ingested so the
    // view is correct even if the notification arrived while hidden.
    [self renderRows];
}

#pragma mark - data ingestion

- (void)setHideSystemServices:(BOOL)hide {
    if (_hideSystemServices == hide) return;
    _hideSystemServices = hide;
    // Re-derive from the last raw set so the toggle takes effect without waiting for
    // the next sensor update.
    [self ingestAttributions:self.lastAttributions activeAttributions:self.lastActiveAttributions];
}

- (void)setStyleOpacity:(CGFloat)opacity corner:(CGFloat)corner border:(CGFloat)border compact:(BOOL)compact {
    // Clamp defensively: a malformed plist must not produce an invisible or
    // absurdly shaped card.
    if (opacity < 0.2) opacity = 0.2;
    if (opacity > 1.0) opacity = 1.0;
    if (corner < 0) corner = 0;
    if (corner > 24) corner = 24;
    if (border < 0) border = 0;
    if (border > 3) border = 3;
    if (_styleOpacity == opacity && _styleCorner == corner &&
        _styleBorder == border && _styleCompact == compact) return;
    _styleOpacity = opacity;
    _styleCorner = corner;
    _styleBorder = border;
    _styleCompact = compact;
    RBLog(@"style apply opacity=%.2f corner=%.0f border=%.0f compact=%d",
          opacity, corner, border, (int)compact);
    // 0.2.29: the menu sits on the host, not inside self.view, so clearing the
    // card does not remove it automatically.
    [self rbDismissRowMenu:nil];
    // Tear down the built UI. -rbView rebuilds lazily from these new values on the
    // next mount; -ingestAttributions keeps the row data, so no sensor state is lost.
    self.view = nil;
    self.contentStack = nil;
    self.rowsStack = nil;
    self.emptyLabel = nil;
    self.toastLabel = nil;
    self.lastRenderSignature = nil;
}

- (void)ingestAttributions:(NSSet *)attributions
         activeAttributions:(NSSet *)activeAttributions {
    self.lastAttributions = attributions;
    self.lastActiveAttributions = activeAttributions;

    // 0.2.3 P0: merge by bundle/name, classify active vs recent, then sort.
    NSMutableDictionary *merged = [NSMutableDictionary dictionary];
    NSMutableArray *order = [NSMutableArray array];

    for (id obj in attributions) {
        // 0.2.1 FIX: the old check was `conformsToProtocol:@protocol(RBAttribution)`.
        // SBSensorActivityAttribution never declares conformance to OUR private
        // protocol, so every entry was skipped -- the log showed attrs=1/2 while the
        // card still said "no app". Check the actual methods instead.
        if (![obj respondsToSelector:@selector(displayName)] &&
            ![obj respondsToSelector:@selector(bundleIdentifier)] &&
            ![obj respondsToSelector:@selector(activeEntityBundleIdentifier)]) {
            RBLog(@"attribution skip class=%@ (no name/bundle selectors)", NSStringFromClass([obj class]));
            continue;
        }

        NSString *bundle = nil, *name = nil;
        if ([obj respondsToSelector:@selector(bundleIdentifier)]) bundle = [obj performSelector:@selector(bundleIdentifier)];
        if (!bundle && [obj respondsToSelector:@selector(activeEntityBundleIdentifier)])
            bundle = [obj performSelector:@selector(activeEntityBundleIdentifier)];
        if ([obj respondsToSelector:@selector(displayName)]) name = [obj performSelector:@selector(displayName)];
        if (!name) name = bundle;
        if (name.length == 0) {
            RBLog(@"attribution skip class=%@ empty name/bundle", NSStringFromClass([obj class]));
            continue;
        }

        BOOL system = NO;
        if ([obj respondsToSelector:@selector(isSystemService)]) {
            id sysVal = [obj valueForKey:@"isSystemService"];   // KVC boxes scalars
            system = [sysVal isKindOfClass:[NSNumber class]] ? [sysVal boolValue] : NO;
        }
        if (self.hideSystemServices && system) {
            RBLog(@"attribution skip system class=%@ name=%@", NSStringFromClass([obj class]), name);
            continue;
        }

        long long sensor = -1;
        if ([obj respondsToSelector:@selector(sensor)]) {
            id sensorVal = [obj valueForKey:@"sensor"];         // KVC boxes scalars
            if ([sensorVal isKindOfClass:[NSNumber class]]) sensor = [sensorVal longLongValue];
        }
        NSString *kind = @"传感器";
        if (sensor == 1) kind = @"相机";
        else if (sensor == 2) kind = @"麦克风";

        BOOL active = activeAttributions ? [activeAttributions containsObject:obj] : NO;
        BOOL recent = NO;
        if (!active) {
            if (activeAttributions) {
                // The object came from the active+recent source but not the active set.
                recent = YES;
            } else if ([obj respondsToSelector:@selector(usedRecently)]) {
                id recentVal = [obj valueForKey:@"usedRecently"];
                recent = [recentVal isKindOfClass:[NSNumber class]] && [recentVal boolValue];
            }
        }

        NSString *key = bundle.length ? bundle : name;

        // 0.2.29: "本次隐藏此应用" only affects this card instance/session.
        // It is checked before duration recording so a hidden app cannot keep
        // a stale timer alive.
        if (key.length && [self.sessionHiddenBundles containsObject:key]) {
            RBLog(@"attribution skip session hidden key=%@", key);
            continue;
        }

        // 0.2.28: track when this app was FIRST seen in the provider feed. The
        // private SBSensorActivityAttribution carries no timestamp we can rely
        // on, so the card records its own first-seen time and ticks a label.
        if (key.length && !self.activeSince[key]) {
            // 0.2.28: record on FIRST SEEN regardless of active. The active
            // set from activeCameraAndMicrophoneActivityAttributions is often
            // empty in the reachability window even while a row is shown, so
            // gating on active made the duration never appear. We keep the
            // first-seen time; the label counts up from here.
            self.activeSince[key] = [NSDate date];
            RBLog(@"duration start key=%@ active=%d", key, (int)active);
        }

        RBLog(@"attribution OK name=%@ bundle=%@ sensor=%lld system=%d active=%d kind=%@",
              name, bundle, sensor, (int)system, (int)active, kind);

        NSMutableDictionary *row = merged[key];
        if (!row) {
            NSMutableArray *kinds = [NSMutableArray arrayWithObject:kind];
            NSMutableArray *raws = [NSMutableArray arrayWithObject:@(sensor)];
            row = [NSMutableDictionary dictionaryWithDictionary:@{
                @"name": name, @"bundle": bundle ?: @"", @"key": key,
                @"kinds": kinds, @"raws": raws,
                @"system": @(system), @"active": @(active), @"recent": @(recent)
            }];
            merged[key] = row;
            [order addObject:key];
        } else {
            NSMutableArray *kinds = row[@"kinds"];
            if (![kinds containsObject:kind]) [kinds addObject:kind];
            NSMutableArray *raws = row[@"raws"];
            NSNumber *rawNumber = @(sensor);
            if (![raws containsObject:rawNumber]) [raws addObject:rawNumber];
            row[@"active"] = @([row[@"active"] boolValue] || active);
            row[@"recent"] = @([row[@"recent"] boolValue] || recent);
            // If a system attribution and a user app share a key, keep the user app.
            row[@"system"] = @([row[@"system"] boolValue] && system);
            NSString *oldName = row[@"name"];
            if (oldName.length < name.length) row[@"name"] = name;
        }
    }

    NSMutableArray *out = [NSMutableArray array];
    for (NSString *key in order) {
        NSMutableDictionary *row = merged[key];
        NSArray *kinds = row[@"kinds"];
        NSArray *raws = row[@"raws"];
        long long primarySensor = [raws.firstObject longLongValue];
        [out addObject:@{
            @"name": row[@"name"], @"bundle": row[@"bundle"], @"key": key,
            @"kind": [kinds componentsJoinedByString:@" + "],
            @"raw": @(primarySensor),
            @"system": row[@"system"], @"active": row[@"active"], @"recent": row[@"recent"]
        }];
    }

    // Stable order: active first, then camera before microphone, then name.
    [out sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        BOOL activeA = [a[@"active"] boolValue];
        BOOL activeB = [b[@"active"] boolValue];
        if (activeA != activeB) return activeA ? NSOrderedAscending : NSOrderedDescending;
        long long rawA = [a[@"raw"] longLongValue];
        long long rawB = [b[@"raw"] longLongValue];
        if (rawA != rawB) return rawA < rawB ? NSOrderedAscending : NSOrderedDescending;
        return [a[@"name"] compare:b[@"name"]
                           options:(NSCaseInsensitiveSearch | NSNumericSearch)];
    }];

    NSUInteger maxRows = 3;
    NSUInteger total = out.count;
    NSArray *visible = total > maxRows ? [out subarrayWithRange:NSMakeRange(0, maxRows)] : out;
    self.hiddenCount = total - visible.count;
    self.rows = [visible copy];
    RBLog(@"ingest rows=%lu from attrs=%lu hidden=%lu",
          (unsigned long)visible.count, (unsigned long)attributions.count, (unsigned long)self.hiddenCount);
    [self renderRows];
}

#pragma mark - row actions

- (void)rbOpenApp:(UITapGestureRecognizer *)gesture {
    RBLog(@"row tap fired");
    NSString *bundle = objc_getAssociatedObject(gesture, &kRBRowAssociationKey);
    if (bundle.length == 0) { RBLog(@"row tap skipped: no bundle"); return; }
    [self rbCollapseAndLaunchBundle:bundle];
}

// 0.2.29: shared by row tap and the menu's "打开这个 App" action. Keeps the
// proven 0.2.18 async-launch path in one place instead of duplicating it.
- (void)rbCollapseAndLaunchBundle:(NSString *)bundle {
    // 0.2.31: this is OUR intentional collapse. Clear the suppress flag first
    // so the deactivateReachability call below is NOT swallowed by the hook;
    // a stale flag here used to block the app-launch exit entirely.
    rbPrivacyInteractionActive = NO;
    // 0.2.15 root cause of "app only opens after reachability ends":
    // deactivateReachability flips reachabilityModeActive to 0 almost instantly
    // (0.2.10 probe: active=0 at +0.1s), but the SBReachabilityWindow teardown is
    // still an in-flight workspace transaction for several hundred ms. An app
    // activation issued inside that window gets queued behind the exit
    // transaction, so the app visibly opens only when the sheet finishes leaving.
    // Collapse now for the UX, but defer the activation until AFTER the exit
    // transaction has settled instead of competing with it.
    Class mgrCls = objc_getClass("SBReachabilityManager");
    id mgr = mgrCls ? [mgrCls performSelector:@selector(sharedInstance)] : nil;
    if (mgr && [mgr respondsToSelector:@selector(deactivateReachability)]) {
        [mgr performSelector:@selector(deactivateReachability)];
        RBLog(@"collapse: deactivateReachability");
    }
    NSString *pending = [bundle copy];
    RBLog(@"tap deferred launch bundle=%@ delay=0.45", bundle);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self performLaunchForBundle:pending];
    });
}

- (void)performLaunchForBundle:(NSString *)bundle {
    RBLog(@"deferred launch firing bundle=%@", bundle);

    // 0.2.11 root cause (from the 0.2.10 probe): reachability was ALREADY active=0
    // at +0.1s and stayed 0 through +2.0s, yet ok=0 and the app took seconds.
    // So the sheet collapse is NOT the bottleneck -- the LAUNCH path is:
    // LSApplicationWorkspace openApplicationWithBundleID: is the external
    // LaunchServices entry point; called from inside SpringBoard it returns an
    // unreliable NO and goes through a slow cross-process activation transaction.
    // Switch to SpringBoard's OWN in-process launch APIs. Each path is guarded,
    // and each logs, so one field run tells us which one actually works.

    // 0.2.13: the 0.2.12 method-name probe gave us the REAL iOS 16 API surface:
    //   SBWorkspace: only 19 methods, NO defaultWorkspace / openApplicationWithBundleID:
    //     -> Cyanide's SBWorkspace path does not exist here; drop it.
    //   SBUIController: activateApplication:fromIcon:location:activationSettings:actions:
    //     -> the true in-process activation selector (0.2.11 used the non-existent
    //        short "activateApplication:", hence skip app=1 ui=1).
    //   LSApplicationWorkspace: openApplicationWithBundleIdentifier:configuration:completionHandler:
    //     -> newer async variant of the slow path.
    // Use SBUIController's internal activation FIRST (switch-to semantics for an
    // app already holding the camera/mic = instant), then the LS async variant,
    // then the old external path. ok=0 on LS was always a caller-validation
    // false negative -- the app does launch, just slowly.

    BOOL activateTried = NO;

    // SBApplication instance from SBApplicationController (verified in Kayoko source).
    Class appCtrlCls = objc_getClass("SBApplicationController");
    id appCtrl = (appCtrlCls && [appCtrlCls respondsToSelector:@selector(sharedInstance)])
        ? [appCtrlCls performSelector:@selector(sharedInstance)] : nil;
    id sbApp = (appCtrl && [appCtrl respondsToSelector:@selector(applicationWithBundleIdentifier:)])
        ? [appCtrl performSelector:@selector(applicationWithBundleIdentifier:) withObject:bundle] : nil;

    // Path A: SBUIController activateApplication:fromIcon:location:activationSettings:actions:
    // Use NSInvocation so the REAL method signature drives argument handling. This
    // avoids ABI corruption if `location` is a struct (CGPoint) vs an object.
    Class uiCtrlCls = objc_getClass("SBUIController");
    id uiCtrl = nil;
    if (uiCtrlCls && [uiCtrlCls respondsToSelector:@selector(sharedInstanceIfExists)]) {
        uiCtrl = [uiCtrlCls performSelector:@selector(sharedInstanceIfExists)];
    }
    if (!uiCtrl && uiCtrlCls && [uiCtrlCls respondsToSelector:@selector(sharedInstance)]) {
        uiCtrl = [uiCtrlCls performSelector:@selector(sharedInstance)];
    }
    // 0.2.15: try the REAL switcher activation path first. FlexiSPY hooks
    // SBUIController activateApplicationFromSwitcher: with an SBApplication
    // argument -- this is the in-process "switch to app" call the system uses.
    // activate5 (Path B below) exists on iOS 16 but 0.2.14 proved on-device that
    // it does NOT bring the app to the foreground by itself.
    SEL switcherSel = sel_registerName("activateApplicationFromSwitcher:");
    if (sbApp && uiCtrl && [uiCtrl respondsToSelector:switcherSel]) {
        @try {
            ((void (*)(id, SEL, id))objc_msgSend)(uiCtrl, switcherSel, sbApp);
            RBLog(@"open via switcher activation bundle=%@ sbApp=%d", bundle, (int)(sbApp != nil));
        } @catch (NSException *ex) {
            RBLog(@"open switcher threw %@", NSStringFromClass([ex class]));
        }
    } else {
        RBLog(@"open switcher skip app=%d ui=%d sel=%d",
              (int)(sbApp != nil), (int)(uiCtrl != nil),
              (int)(uiCtrl && [uiCtrl respondsToSelector:switcherSel]));
    }

    // 0.2.16: 0.2.15 field log proved iOS 16 has NO
    // activateApplicationFromSwitcher: on SBUIController (sel=0). Dump every
    // activation/launch selector the REAL class exposes once, so the next run
    // tells us exactly what is available instead of guessing again.
    static dispatch_once_t rbProbeOnce;
    dispatch_once(&rbProbeOnce, ^{
        if (uiCtrl) {
            unsigned int mcount = 0;
            Method *mlist = class_copyMethodList([uiCtrl class], &mcount);
            NSMutableArray *hits = [NSMutableArray array];
            for (unsigned int i = 0; i < mcount; i++) {
                NSString *mn = NSStringFromSelector(method_getName(mlist[i]));
                if ([mn rangeOfString:@"activate" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                    [mn rangeOfString:@"launch" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                    [mn rangeOfString:@"openApp" options:NSCaseInsensitiveSearch].location != NSNotFound) {
                    [hits addObject:mn];
                }
            }
            free(mlist);
            RBLog(@"probe SBUIController methods=%u activation=%@",
                  mcount, [hits componentsJoinedByString:@","]);
        }
    });

    // 0.2.16: FBSSystemService is the FrontBoard-side in-process actuator and
    // iOS 16 headers confirm -openApplication:options:withResult:. Try it with
    // the bundle id (NOT an SBApplication) and an empty options dict. The result
    // block is declared id; pass a zero-arg block -- ObjC callers ignore extra
    // arguments, so this cannot crash whatever the real block signature is.
    Class fbsCls = objc_getClass("FBSSystemService");
    id fbsSvc = nil;
    if (fbsCls && [fbsCls respondsToSelector:@selector(sharedService)]) {
        fbsSvc = [fbsCls performSelector:@selector(sharedService)];
    }
    if (!fbsSvc && fbsCls && [fbsCls respondsToSelector:@selector(sharedInstance)]) {
        fbsSvc = [fbsCls performSelector:@selector(sharedInstance)];
    }
    SEL fbsSel = sel_registerName("openApplication:options:withResult:");
    if (fbsSvc && [fbsSvc respondsToSelector:fbsSel]) {
        @try {
            void (^noop)(void) = ^{};
            ((void (*)(id, SEL, id, id, id))objc_msgSend)(fbsSvc, fbsSel, bundle, @{}, noop);
            RBLog(@"open via FBSSystemService bundle=%@ svc=%d", bundle, (int)(fbsSvc != nil));
        } @catch (NSException *ex) {
            RBLog(@"open FBS threw %@", NSStringFromClass([ex class]));
        }
    } else {
        RBLog(@"open FBS skip cls=%d svc=%d sel=%d",
              (int)(fbsCls != nil), (int)(fbsSvc != nil),
              (int)(fbsSvc && [fbsSvc respondsToSelector:fbsSel]));
    }

    SEL activateSel = sel_registerName("activateApplication:fromIcon:location:activationSettings:actions:");
    if (sbApp && uiCtrl && [uiCtrl respondsToSelector:activateSel]) {
        NSMethodSignature *sig = [uiCtrl methodSignatureForSelector:activateSel];
        if (sig) {
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setTarget:uiCtrl];
            [inv setSelector:activateSel];
            id arg1 = sbApp;
            [inv setArgument:&arg1 atIndex:2];          // application
            for (NSUInteger i = 3; i < [sig numberOfArguments]; i++) {
                id zero = nil;
                [inv setArgument:&zero atIndex:i];      // fromIcon/location/settings/actions
            }
            [inv invoke];
            activateTried = YES;
            // 0.2.14: DO NOT short-circuit here. Field log showed activate5 runs
            // (argc=7) but does NOT bring the app forward -- setting launched=YES
            // skipped the LS path that actually worked in 0.2.7~0.2.12. Fire both.
            RBLog(@"open via SBUIController activate5 bundle=%@ sbApp=%d argc=%lu",
                  bundle, (int)(sbApp != nil), (unsigned long)[sig numberOfArguments]);
        } else {
            RBLog(@"open SBUIController no signature");
        }
    } else {
        RBLog(@"open SBUIController skip app=%d ui=%d sel=%d",
              (int)(sbApp != nil), (int)(uiCtrl != nil),
              (int)(uiCtrl && [uiCtrl respondsToSelector:activateSel]));
    }

    // Path B: LSApplicationWorkspace openApplicationWithBundleID: -- the ONLY
    // path that verifiably launches the app. 0.2.17 field log was decisive:
    //   +34027ms activate5 returned (19ms)
    //   +44031ms openApplicationWithBundleID: returned  -> BLOCKED 10004ms
    // Calling LS synchronously from inside SpringBoard self-deadlocks: the XPC
    // activation callback must be serviced on SpringBoard's own main runloop,
    // which is stuck waiting for this very call to return. ok=0 is the timeout,
    // not a "false negative". That 10s main-thread stall is the entire delay --
    // it also freezes the activate5/FBS activation transaction issued above.
    // FIX (0.2.18): fire LS ASYNCHRONOUSLY. The XPC request still goes out, but
    // the main thread is released immediately so the activation transaction can
    // be serviced at once. Keep activate5/FBS on the main thread (instant).
    Class lsCls = objc_getClass("LSApplicationWorkspace");
    LSApplicationWorkspace *ls = (LSApplicationWorkspace *)[lsCls performSelector:@selector(defaultWorkspace)];
    if ([ls respondsToSelector:@selector(openApplicationWithBundleID:)]) {
        RBLog(@"open app LS dispatched bundle=%@ activateTried=%d", bundle, (int)activateTried);
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            BOOL ok = [ls openApplicationWithBundleID:bundle];
            RBLog(@"open app LS returned bundle=%@ ok=%d", bundle, (int)ok);
        });
    }

    // 0.2.17 DIAGNOSTIC ONLY: pulse the target app's activation state every
    // 0.5s for 6s. All request APIs above return within the same millisecond;
    // this reveals WHERE the reported ~5s actually goes:
    //   state flips to active at +5s  -> SpringBoard transaction queue
    //   state active at +0.5s but UI appears at +5s -> app COLD START (not fixable
    //      from a tweak; it is the app's own launch/first-frame cost)
    //   state stays inactive          -> none of the activation calls worked
    if (rbPulseTimer) { [rbPulseTimer invalidate]; rbPulseTimer = nil; }
    rbPulseCount = 0;
    NSDictionary *info = @{@"bundle": bundle, @"app": (sbApp ?: NSNull.null)};
    NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:0.5
                                                     target:self
                                                   selector:@selector(rbLaunchPulse:)
                                                   userInfo:info
                                                    repeats:YES];
    rbPulseTimer = timer;
    [timer fire];
}

// 0.2.17 diagnostic: one pulse per 0.5s, up to 12, then invalidate.
- (void)rbLaunchPulse:(NSTimer *)timer {
    NSDictionary *info = timer.userInfo;
    NSString *bundle = info[@"bundle"];
    id app = info[@"app"];
    if (app == NSNull.null) app = nil;
    NSInteger n = ++rbPulseCount;

    NSString *st = @"?";
    NSArray *keys = @[@"_activationState", @"activationState", @"isActive", @"activated"];
    for (NSString *k in keys) {
        @try {
            id v = [app valueForKey:k];
            if (v) { st = [NSString stringWithFormat:@"%@=%@", k, v]; break; }
        } @catch (NSException *ex) {
            st = [NSString stringWithFormat:@"%@-threw", k];
        }
    }
    RBLog(@"launch pulse #%ld bundle=%@ state=%@", (long)n, bundle, st);
    if (n >= 12) { [timer invalidate]; rbPulseCount = 0; rbPulseTimer = nil; }
}

// 0.2.29: long press now opens a compact action menu. It is added to the card's
// HOST (container/stack), not to the clipped card root, so it is never cut off
// and never rebuilt by renderRows. RDB2 tag lets the hitTest bridge accept it.
- (void)rbShowRowMenu:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateBegan) {
        // 0.2.31: mark interaction active AT ONSET. Field log 0.2.30 proved the
        // SYSTEM deactivates Reachability ~236ms after longpress Began while the
        // finger is still down -- before the Ended menu ever shows. Suppress from
        // here so the sheet cannot collapse under a held row.
        rbPrivacyInteractionActive = YES;
        RBLog(@"row longpress fired");
        return; // show on Ended only, after the finger is lifted.
    }
    if (gesture.state == UIGestureRecognizerStateCancelled ||
        gesture.state == UIGestureRecognizerStateFailed) {
        rbPrivacyInteractionActive = NO;
        return;
    }
    if (gesture.state != UIGestureRecognizerStateEnded) return;

    NSDictionary *row = objc_getAssociatedObject(gesture, &kRBLongPressRowKey);
    NSString *bundle = row[@"bundle"] ?: @"";
    NSString *name = row[@"name"] ?: @"";
    if (row.count == 0) { rbPrivacyInteractionActive = NO; RBLog(@"row menu skipped: no row context"); return; }

    [self rbDismissRowMenu:nil];
    // rbDismissRowMenu clears the flag (correct for outside-tap and item-tap),
    // but we are about to show a NEW menu, so re-arm the suppression here.
    rbPrivacyInteractionActive = YES;

    UIView *host = self.view.superview ?: self.view;
    if (!host) { RBLog(@"row menu skipped: no host"); return; }

    CGFloat itemH = 28.0;
    NSArray *titles = @[@"复制 Bundle ID", @"复制应用名称", @"打开这个 App",
                        @"复制状态摘要", @"本次隐藏此应用"];
    CGFloat menuW = 188.0;
    CGFloat menuH = titles.count * itemH + 12.0;
    CGRect anchor = [gesture.view convertRect:gesture.view.bounds toView:host];
    CGFloat x = CGRectGetMidX(anchor) - menuW / 2.0;
    x = MAX(8.0, MIN(x, CGRectGetWidth(host.bounds) - menuW - 8.0));
    CGFloat y = CGRectGetMaxY(anchor) + 4.0;
    if (y + menuH > CGRectGetHeight(host.bounds) - 8.0) {
        y = CGRectGetMinY(anchor) - menuH - 4.0;
    }
    y = MAX(8.0, MIN(y, CGRectGetHeight(host.bounds) - menuH - 8.0));

    UIView *overlay = [[UIView alloc] initWithFrame:host.bounds];
    overlay.backgroundColor = [UIColor clearColor];
    overlay.tag = kRBMenuTag;
    overlay.userInteractionEnabled = YES;
    UITapGestureRecognizer *outside =
        [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(rbDismissRowMenu:)];
    [overlay addGestureRecognizer:outside];

    UIView *menu = [[UIView alloc] initWithFrame:CGRectMake(x, y, menuW, menuH)];
    menu.backgroundColor = [UIColor colorWithWhite:0.10 alpha:0.96];
    menu.layer.cornerRadius = 12;
    menu.layer.cornerCurve = kCACornerCurveContinuous;
    menu.layer.borderWidth = 1;
    menu.layer.borderColor = [[UIColor whiteColor] colorWithAlphaComponent:0.18].CGColor;
    menu.clipsToBounds = YES;
    menu.tag = kRBMenuTag;
    menu.userInteractionEnabled = YES;
    objc_setAssociatedObject(menu, &kRBMenuContextKey, row, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    for (NSUInteger i = 0; i < titles.count; i++) {
        UIButton *item = [UIButton buttonWithType:UIButtonTypeCustom];
        item.frame = CGRectMake(16, 6 + i * itemH, menuW - 22, itemH - 2);
        item.tag = (NSInteger)i;
        [item setTitle:titles[i] forState:UIControlStateNormal];
        [item setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        [item setTitleColor:[[UIColor whiteColor] colorWithAlphaComponent:0.55]
                   forState:UIControlStateHighlighted];
        item.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
        item.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
        // 0.2.29 buildfix: contentEdgeInsets is deprecated under iOS 15+ SDK
        // (-Werror). The x=16 frame above gives the same 10pt inner padding.
        [item addTarget:self action:@selector(rbMenuTapped:) forControlEvents:UIControlEventTouchUpInside];
        [menu addSubview:item];
    }

    [host addSubview:overlay];
    [host addSubview:menu];
    self.menuOverlay = overlay;
    self.menuView = menu;
    RBLog(@"row menu show key=%@ items=%lu", bundle.length ? bundle : name,
          (unsigned long)titles.count);
}

- (void)rbDismissRowMenu:(id)sender {
    (void)sender;
    rbPrivacyInteractionActive = NO;
    if (!self.menuView && !self.menuOverlay) return;
    [self.menuView removeFromSuperview];
    [self.menuOverlay removeFromSuperview];
    self.menuView = nil;
    self.menuOverlay = nil;
    RBLog(@"row menu dismiss");
}

- (void)rbMenuTapped:(UIButton *)button {
    NSDictionary *row = objc_getAssociatedObject(button.superview, &kRBMenuContextKey);
    if (row.count == 0) { [self rbDismissRowMenu:nil]; return; }
    NSString *bundle = row[@"bundle"] ?: @"";
    NSString *name = row[@"name"] ?: @"";
    NSString *key = bundle.length ? bundle : name;
    NSInteger idx = button.tag;
    RBLog(@"row menu action=%ld key=%@", (long)idx, key);
    [self rbDismissRowMenu:nil];

    switch (idx) {
        case 0: {
            if (bundle.length == 0) break;
            [UIPasteboard generalPasteboard].string = bundle;
            RBLog(@"copy bundle=%@", bundle);
            [self rbShowCopiedToast:bundle];
            break;
        }
        case 1: {
            if (name.length == 0) break;
            [UIPasteboard generalPasteboard].string = name;
            RBLog(@"copy app name=%@", name);
            [self rbShowCopiedToast:name];
            break;
        }
        case 2: {
            if (bundle.length == 0) break;
            [self rbCollapseAndLaunchBundle:bundle];
            break;
        }
        case 3: {
            NSString *state = [row[@"active"] boolValue]
                ? @"正在使用"
                : ([row[@"recent"] boolValue] ? @"最近使用" : @"传感器");
            NSString *duration = [self rbDurationTextForBundle:key];
            NSString *summary = [NSString stringWithFormat:@"%@ · %@ · %@ · %@ · %@",
                                 name, row[@"kind"] ?: @"传感器", state,
                                 duration.length ? duration : @"无时长", bundle];
            [UIPasteboard generalPasteboard].string = summary;
            RBLog(@"copy summary key=%@", key);
            [self rbShowCopiedToast:summary];
            break;
        }
        case 4: {
            if (key.length == 0) break;
            [self.sessionHiddenBundles addObject:key];
            [self.activeSince removeObjectForKey:key];
            [self ingestAttributions:self.lastAttributions
                   activeAttributions:self.lastActiveAttributions];
            RBLog(@"session hidden key=%@", key);
            break;
        }
        default:
            break;
    }
}

// 0.2.25/0.2.29: short visual confirmation of copy actions. The toast is added
// to the card root (which clips to the rounded card), never takes touches
// (userInteractionEnabled = NO), so it cannot disturb the hitTest bridge that
// accepts only tagged row/menu views.
- (void)rbShowCopiedToast:(NSString *)bundle {
    UIView *root = self.view;
    if (!root) { RBLog(@"copy toast skipped: no card view"); return; }

    if (!self.toastLabel || self.toastLabel.superview != root) {
        UILabel *toast = [[UILabel alloc] init];
        toast.translatesAutoresizingMaskIntoConstraints = NO;
        toast.textAlignment = NSTextAlignmentCenter;
        toast.font = [UIFont systemFontOfSize:(_styleCompact ? 12 : 13) weight:UIFontWeightSemibold];
        toast.textColor = [UIColor whiteColor];
        toast.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.82];
        toast.layer.cornerRadius = 10;
        toast.layer.cornerCurve = kCACornerCurveContinuous;
        toast.clipsToBounds = YES;
        toast.userInteractionEnabled = NO;   // must not enter the reachability hitTest
        toast.alpha = 0.0;
        [root addSubview:toast];
        CGFloat pad = _styleCompact ? 8 : 10;
        // 0.2.27: pin to the TOP-LEFT corner, furthest from any row the finger
        // holds down, and clear of the centred usage-duration labels.
        [NSLayoutConstraint activateConstraints:@[
            [toast.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:pad],
            [toast.topAnchor constraintEqualToAnchor:root.topAnchor constant:pad],
            [toast.leadingAnchor constraintGreaterThanOrEqualToAnchor:root.leadingAnchor constant:pad],
            [toast.trailingAnchor constraintLessThanOrEqualToAnchor:root.trailingAnchor constant:-pad],
            [toast.heightAnchor constraintGreaterThanOrEqualToConstant:26],
        ]];
        self.toastLabel = toast;
    }

    // 0.2.26: short and sweet -- the user only needs "copied", not the full
    // bundle ID (which was long and easy to cover with a finger).
    (void)bundle;
    NSString *text = @"已复制";
    self.toastLabel.text = text;
    RBLog(@"copy toast show text=%@", text);

    [UIView animateWithDuration:0.18 animations:^{
        self.toastLabel.alpha = 1.0;
    } completion:^(BOOL finished) {
        (void)finished;
        // Weak-ish capture: dispatch_after retains self only for the delay, then
        // releases; no repeating timer / retain cycle (ARC-safe, unlike 0.2.17).
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.4 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            __strong typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            [UIView animateWithDuration:0.35 animations:^{
                strongSelf.toastLabel.alpha = 0.0;
            }];
        });
    }];
}

#pragma mark - usage duration

// 0.2.28: activeCameraAndMicrophoneActivityAttributions is frequently empty
// even while a row is visible, so the row's `active` flag is NOT a reliable
// gate. ingestAttributions: now records first-seen time for every rendered row;
// any recorded bundle gets a live label regardless of that flag.
- (NSString *)rbDurationTextForBundle:(NSString *)bundle {
    if (bundle.length == 0) return @"";
    NSDate *since = self.activeSince[bundle];
    if (!since) return @"";
    NSTimeInterval secs = [[NSDate date] timeIntervalSinceDate:since];
    if (secs < 0) secs = 0;
    long total = (long)secs;
    if (total < 60) return [NSString stringWithFormat:@"%ld秒", total];
    long mins = total / 60, rem = total % 60;
    if (mins < 60) return [NSString stringWithFormat:@"%ld分%02ld秒", mins, rem];
    long hours = mins / 60;
    return [NSString stringWithFormat:@"%ld时%02ld分", hours, mins % 60];
}

// 1s tick: update the duration labels in place. Never touches rowsStack's
// arranged subviews or the render signature, so a tick cannot rebuild a row
// mid-touch (the 0.2.7 gesture-death bug).
- (void)rbTickDurations:(NSTimer *)timer {
    (void)timer;
    if (!self.rowsStack) return;
    for (UIView *box in self.rowsStack.arrangedSubviews) {
        if (box.tag != 0x52444231) continue;
        for (UIView *v in box.subviews) {
            if (![v isKindOfClass:[UILabel class]]) continue;
            NSString *key = objc_getAssociatedObject(v, &kRBDurationKeyKey);
            if (!key) continue;
            NSString *text = [self rbDurationTextForBundle:key];
            UILabel *label = (UILabel *)v;
            if (![text isEqualToString:label.text]) {
                label.text = text;
                // 0.2.28: first few non-empty updates prove the ticker is alive
                // without spamming the log every second.
                if (text.length && rbDurationShowLogged < 5) {
                    rbDurationShowLogged++;
                    RBLog(@"duration label key=%@ text=%@", key, text);
                }
            }
            break;
        }
    }
}

#pragma mark - view

- (void)buildView {
    // VISIBLE CARD (0.0.5): the previous card was a fully transparent view whose
    // height got stretched to the whole reachability area by the outer stack, so
    // it read as "nothing there". Give it a real surface and pin its height to
    // its content (equality, not >=) so the stack cannot stretch it.
    // 0.0.7: raise contrast (a 0.42 black card on a dark blurred wallpaper is
    // indistinguishable from nothing) and add an always-present title so the card
    // is recognizable even before any sensor attribution arrives.
    // 0.2.19: all metrics derive from the style set by the user. Defaults
    // (opacity .72 / corner 16 / not compact) reproduce the original look.
    CGFloat pad = _styleCompact ? 10 : 14;
    CGFloat gap = _styleCompact ? 5 : 8;

    UIView *root = [[UIView alloc] initWithFrame:CGRectZero];
    root.translatesAutoresizingMaskIntoConstraints = NO;
    root.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:_styleOpacity];
    root.layer.cornerRadius = _styleCorner;
    root.layer.cornerCurve = kCACornerCurveContinuous;
    // 0.2.20: border width is user-adjustable (0..3 pt). 0 hides the white ring.
    root.layer.borderWidth = _styleBorder;
    root.layer.borderColor = [[UIColor whiteColor] colorWithAlphaComponent:0.75].CGColor;
    root.clipsToBounds = YES;
    // Highest hugging/compression resistance: never grow to fill spare space.
    [root setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisVertical];
    [root setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisVertical];
    self.view = root;

    self.contentStack = [[UIStackView alloc] init];
    self.contentStack.axis = UILayoutConstraintAxisVertical;
    self.contentStack.spacing = gap;
    self.contentStack.alignment = UIStackViewAlignmentFill;
    self.contentStack.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:self.contentStack];

    // Equality: card height follows its content exactly (top pad + content +
    // bottom pad). A >= here is what let the outer stack stretch it before.
    [NSLayoutConstraint activateConstraints:@[
        [self.contentStack.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:pad],
        [self.contentStack.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-pad],
        [self.contentStack.topAnchor constraintEqualToAnchor:root.topAnchor constant:pad],
        [root.heightAnchor constraintEqualToAnchor:self.contentStack.heightAnchor constant:pad * 2],
        [self.contentStack.heightAnchor constraintGreaterThanOrEqualToConstant:40],
    ]];

    UILabel *header = [[UILabel alloc] init];
    header.text = @"隐私";
    header.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.55];
    header.font = [UIFont systemFontOfSize:(_styleCompact ? 10 : 11) weight:UIFontWeightSemibold];
    [self.contentStack addArrangedSubview:header];

    // Rows live in their own stack so renderRows() can clear/repopulate without
    // ever removing the permanent header (a detached arranged subview cannot be
    // re-added, which silently dropped the header in an earlier draft).
    self.rowsStack = [[UIStackView alloc] init];
    self.rowsStack.axis = UILayoutConstraintAxisVertical;
    self.rowsStack.spacing = gap;
    self.rowsStack.alignment = UIStackViewAlignmentFill;
    [self.contentStack addArrangedSubview:self.rowsStack];

    self.emptyLabel = [[UILabel alloc] init];
    self.emptyLabel.text = @"当前没有应用使用相机或麦克风";
    self.emptyLabel.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.92];
    self.emptyLabel.font = [UIFont systemFontOfSize:(_styleCompact ? 12 : 14) weight:UIFontWeightMedium];
    self.emptyLabel.numberOfLines = 0;
    self.emptyLabel.textAlignment = NSTextAlignmentLeft;
}

- (void)renderRows {
    // Sensor pushes may arrive before the card is ever presented. There is no UI
    // to update yet; -rbView will render from self.rows on first access.
    if (!self.rowsStack) return;

    // 0.2.7: the provider pushes on EVERY domain update (the logs show many per
    // second). Rebuilding all rows each time destroys the row view mid-touch and
    // kills its gesture recognizers. Rebuild only when the rendered content
    // actually changes.
    NSMutableString *sig = [NSMutableString string];
    [sig appendFormat:@"h=%lu|", (unsigned long)self.hiddenCount];
    for (NSDictionary *row in self.rows) {
        [sig appendFormat:@"%@:%@:%@:%@:%@|",
            row[@"key"] ?: @"", row[@"kind"] ?: @"",
            row[@"active"] ?: @"", row[@"recent"] ?: @"", row[@"bundle"] ?: @""];
    }
    if (self.lastRenderSignature && [self.lastRenderSignature isEqualToString:sig]) return;
    self.lastRenderSignature = sig;

    for (UIView *v in [self.rowsStack.arrangedSubviews copy]) {
        [self.rowsStack removeArrangedSubview:v];
        [v removeFromSuperview];
    }

    if (self.rows.count == 0) {
        [self.rowsStack addArrangedSubview:self.emptyLabel];
        return;
    }

    for (NSDictionary *row in self.rows) {
        [self.rowsStack addArrangedSubview:[self rowViewFor:row]];
    }

    if (self.hiddenCount > 0) {
        UILabel *more = [[UILabel alloc] init];
        more.text = [NSString stringWithFormat:@"还有 %lu 项", (unsigned long)self.hiddenCount];
        more.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.6];
        more.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
        more.textAlignment = NSTextAlignmentLeft;
        [self.rowsStack addArrangedSubview:more];
    }
}

- (UIView *)rowViewFor:(NSDictionary *)row {
    CGFloat pad = _styleCompact ? 9 : 12;
    CGFloat vpad = _styleCompact ? 6 : 8;
    UIView *box = [[UIView alloc] init];
    box.translatesAutoresizingMaskIntoConstraints = NO;
    box.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.12];
    box.layer.cornerRadius = _styleCompact ? 9 : 12;
    box.layer.cornerCurve = kCACornerCurveContinuous;
    box.tag = 0x52444231; // 'RDB1' row; 'RDB2' menu/overlay is also accepted
    box.userInteractionEnabled = YES;

    NSString *rowBundle = row[@"bundle"];
    if (rowBundle.length) {
        UITapGestureRecognizer *tap =
            [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(rbOpenApp:)];
        UILongPressGestureRecognizer *longPress =
            [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(rbShowRowMenu:)];
        longPress.minimumPressDuration = 0.5;
        objc_setAssociatedObject(tap, &kRBRowAssociationKey, rowBundle, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(longPress, &kRBRowAssociationKey, rowBundle, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(longPress, &kRBLongPressRowKey, row, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [tap requireGestureRecognizerToFail:longPress];
        [box addGestureRecognizer:tap];
        [box addGestureRecognizer:longPress];
    }

    UIView *dot = [[UIView alloc] init];
    dot.translatesAutoresizingMaskIntoConstraints = NO;
    dot.layer.cornerRadius = 5;
    BOOL isCamera = ([row[@"raw"] longLongValue] == 1);
    dot.backgroundColor = isCamera ? [UIColor systemGreenColor] : [UIColor systemOrangeColor];
    [box addSubview:dot];

    UILabel *title = [[UILabel alloc] init];
    title.text = row[@"name"];
    title.font = [UIFont systemFontOfSize:(_styleCompact ? 13 : 15) weight:UIFontWeightSemibold];
    title.textColor = [row[@"system"] boolValue]
        ? [[UIColor whiteColor] colorWithAlphaComponent:0.6]
        : [UIColor whiteColor];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    [box addSubview:title];

    // 0.2.27: usage duration on the right of the title line. Not interactive
    // (so the container hitTest bridge is untouched). Text refreshed by a
    // 1s timer WITHOUT rebuilding the row -- rebuilding mid-touch kills taps.
    UILabel *duration = [[UILabel alloc] init];
    duration.font = [UIFont monospacedDigitSystemFontOfSize:(_styleCompact ? 11 : 12)
                                                     weight:UIFontWeightSemibold];
    duration.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.75];
    duration.textAlignment = NSTextAlignmentRight;
    duration.userInteractionEnabled = NO;
    duration.translatesAutoresizingMaskIntoConstraints = NO;
    NSString *dKey = (row[@"bundle"] ?: row[@"name"]) ?: @"";
    duration.text = [self rbDurationTextForBundle:dKey];
    objc_setAssociatedObject(duration, &kRBDurationKeyKey, dKey, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [box addSubview:duration];

    UILabel *sub = [[UILabel alloc] init];
    // 0.2.3: state first (active/recent), then localized kind(s), optional
    // system-service tag and bundle id. The bundle id stays as a stable
    // technical identifier; it is the only way to recognise a system attribution.
    NSString *state = [row[@"active"] boolValue]
        ? @"正在使用"
        : ([row[@"recent"] boolValue] ? @"最近使用" : @"传感器");
    NSMutableArray *parts = [NSMutableArray arrayWithObject:state];
    [parts addObject:(row[@"kind"] ?: @"传感器")];
    if ([row[@"system"] boolValue]) [parts addObject:@"系统服务"];
    NSString *bundle = row[@"bundle"];
    if (bundle.length) [parts addObject:bundle];
    sub.text = [parts componentsJoinedByString:@" · "];
    sub.font = [UIFont systemFontOfSize:(_styleCompact ? 10 : 11) weight:UIFontWeightRegular];
    sub.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.55];
    sub.numberOfLines = 1;
    sub.lineBreakMode = NSLineBreakByTruncatingTail;
    sub.translatesAutoresizingMaskIntoConstraints = NO;
    [box addSubview:sub];

    [NSLayoutConstraint activateConstraints:@[
        [dot.leadingAnchor constraintEqualToAnchor:box.leadingAnchor constant:pad],
        [dot.centerYAnchor constraintEqualToAnchor:box.centerYAnchor],
        [dot.widthAnchor constraintEqualToConstant:10],
        [dot.heightAnchor constraintEqualToConstant:10],

        [title.leadingAnchor constraintEqualToAnchor:dot.trailingAnchor constant:10],
        [title.trailingAnchor constraintEqualToAnchor:duration.leadingAnchor constant:-8],
        [title.topAnchor constraintEqualToAnchor:box.topAnchor constant:vpad],

        [duration.trailingAnchor constraintEqualToAnchor:box.trailingAnchor constant:-pad],
        [duration.topAnchor constraintEqualToAnchor:box.topAnchor constant:vpad],
        [duration.widthAnchor constraintLessThanOrEqualToConstant:72],

        [sub.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
        [sub.trailingAnchor constraintEqualToAnchor:title.trailingAnchor],
        [sub.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:2],
        [sub.bottomAnchor constraintEqualToAnchor:box.bottomAnchor constant:-vpad],
        [box.heightAnchor constraintGreaterThanOrEqualToConstant:(_styleCompact ? 44 : 52)],
    ]];
    return box;
}

@end
