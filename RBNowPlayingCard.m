#import "RBNowPlayingCard.h"
#import "RBPrivacyCard.h"   // RBLog + shared interaction suppression
#import <CoreFoundation/CoreFoundation.h>
#import <math.h>
#import <dlfcn.h>

// 'RDB6': transport buttons are the ONLY interactive parts of this card, so the
// card body stays transparent to touches and the Reachability dismiss gesture
// keeps working anywhere else on the card.
static NSInteger const kRBTransportTag = 0x52444236;

// MRMediaRemoteCommand values we actually send. Toggle covers both play and
// pause, so there is no separate play/pause bookkeeping to get out of sync.
static int const kRBCmdTogglePlayPause = 2;
static int const kRBCmdNextTrack = 4;
static int const kRBCmdPreviousTrack = 5;
// 24 = kMRMediaRemoteCommandSeekToPlaybackPosition. The position rides in the
// userInfo dictionary, so the existing send signature already fits and there is
// nothing extra to dlsym.
static int const kRBCmdSeekToPlaybackPosition = 24;
static NSString *const kRBOptionPlaybackPosition = @"kMRMediaRemoteOptionPlaybackPosition";

// 'RDB7': the scrubber is the only view on any card that swallows a DRAG. It has
// to be whitelisted in the container's hitTest or the touch never reaches it.
static NSInteger const kRBScrubberTag = 0x52444237;
// 'RDB8': the empty-state music app buttons. One tag per app from this base
// ('RDB8' + index); the container's hitTest accepts the whole band.
static NSInteger const kRBOpenTag = 0x52444238;
// Last-resort target when none of the music apps below is installed (or when
// LSApplicationProxy cannot be reached at all).
static NSString *const kRBAppleMusicBundleID = @"com.apple.Music";

// The now-playing dictionary is keyed by the identifier strings themselves, so
// these match the exported kMRMediaRemoteNowPlayingInfo* constants without
// having to dlsym every one of them.
static NSString *const kRBNPTitleKey = @"kMRMediaRemoteNowPlayingInfoTitle";
static NSString *const kRBNPArtistKey = @"kMRMediaRemoteNowPlayingInfoArtist";
static NSString *const kRBNPDurationKey = @"kMRMediaRemoteNowPlayingInfoDuration";
static NSString *const kRBNPElapsedKey = @"kMRMediaRemoteNowPlayingInfoElapsedTime";
static NSString *const kRBNPRateKey = @"kMRMediaRemoteNowPlayingInfoPlaybackRate";

typedef void (^RBNPInfoHandler)(CFDictionaryRef information);
typedef void (*RBNPGetInfoFn)(dispatch_queue_t queue, RBNPInfoHandler handler);
typedef Boolean (*RBNPSendFn)(int command, CFDictionaryRef userInfo);

static void *rbMediaRemoteHandle(void) {
    static void *handle = NULL;
    static BOOL tried = NO;
    if (tried) return handle;
    tried = YES;
    // Absolute system path: roothide only redirects /var/jb, so this is the real
    // framework even on a roothide jailbreak.
    handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY);
    RBLog(@"nowplaying mediaRemote handle=%d", (int)(handle != NULL));
    return handle;
}

static RBNPGetInfoFn rbNPGetInfo(void) {
    void *h = rbMediaRemoteHandle();
    if (!h) return NULL;
    return (RBNPGetInfoFn)dlsym(h, "MRMediaRemoteGetNowPlayingInfo");
}

static RBNPSendFn rbNPSendCommand(void) {
    void *h = rbMediaRemoteHandle();
    if (!h) return NULL;
    return (RBNPSendFn)dlsym(h, "MRMediaRemoteSendCommand");
}

// --- source app -------------------------------------------------------------
//
// "正在播放" from Music, from Spotify and from a podcast app are three very
// different things, and until now the card said nothing about which one it was.

typedef void (*RBNPGetClientFn)(dispatch_queue_t queue, void (^handler)(id client));

// The client that MRMediaRemoteGetNowPlayingClient hands back is a private
// MRNowPlayingClient instance. Declaring just the one method keeps the call
// type-checked instead of falling back to performSelector, which loses the
// return type and trips -Werror.
@protocol RBNPClient <NSObject>
- (NSString *)bundleIdentifier;
@end

static RBNPGetClientFn rbNPGetClient(void) {
    void *h = rbMediaRemoteHandle();
    if (!h) return NULL;
    return (RBNPGetClientFn)dlsym(h, "MRMediaRemoteGetNowPlayingClient");
}

// LSApplicationWorkspace is the FALLBACK: it needs no entitlement and no URL
// scheme whitelist. Declared as a protocol so the call is type-checked -- a bare
// performSelector would lose the BOOL return type and trips -Werror.
@protocol RBAppLaunching <NSObject>
+ (id)defaultWorkspace;
- (BOOL)openApplicationWithBundleID:(NSString *)bundleID;
@end

// 🔴 0.4.4: openApplicationWithBundleID: is SYNCHRONOUS inside SpringBoard -- it
// does not return until the target app reaches the foreground. The 0.4.3 field
// log measures it: touch down at +28176ms, the call returned at +38332ms with
// ok=0, and the launch only began at +38911ms. Ten seconds of frozen main
// thread, which the user reads as "opening the app is slow".
//
// SpringBoardServices has the entry point the system itself uses:
// SBSLaunchApplicationWithIdentifier only SUBMITS the launch request. It lives
// in a private framework, so it is dlopen'd -- a link-time dependency that fails
// to resolve would take the whole dylib down (Safe Mode) for one button.
typedef int (*RBLaunchFn)(CFStringRef bundleID, Boolean suspended);

static RBLaunchFn rbLaunchFn(void) {
    static RBLaunchFn fn = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *h = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices",
                         RTLD_LAZY);
        if (h) fn = (RBLaunchFn)dlsym(h, "SBSLaunchApplicationWithIdentifier");
        RBLog(@"nowplaying launch handle sbs=%d", (int)(fn != NULL));
    });
    return fn;
}

static void rbOpenApp(NSString *bundleID) {
    if (!bundleID.length) return;
    // 🔴 Never on the main thread. Even the lightweight path reaches FrontBoard
    // over XPC, and the panel has to stay free to animate away the instant the
    // button is tapped -- whatever the target app does next is its own business.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        CFTimeInterval t0 = CFAbsoluteTimeGetCurrent();
        RBLaunchFn launch = rbLaunchFn();
        if (launch) {
            int rc = launch((__bridge CFStringRef)bundleID, false);
            RBLog(@"nowplaying launch via=sbs app=%@ rc=%d took=%.1fms",
                  bundleID, rc, (CFAbsoluteTimeGetCurrent() - t0) * 1000.0);
            if (rc == 0) return;
        }
        Class cls = NSClassFromString(@"LSApplicationWorkspace");
        if (!cls) {
            RBLog(@"nowplaying launch skipped: no LSApplicationWorkspace");
            return;
        }
        // Two casts, both load-bearing under -Werror: sending +defaultWorkspace
        // to a Class-typed receiver makes the compiler look for a CLASS method on
        // an unrelated type, so the receiver goes through bare id first (at
        // runtime a Class still dispatches to its metaclass); the result is then
        // cast back to the protocol so the BOOL return survives.
        id<RBAppLaunching> ws = (id<RBAppLaunching>)[(id)cls defaultWorkspace];
        if (!ws) return;
        BOOL ok = [ws openApplicationWithBundleID:bundleID];
        RBLog(@"nowplaying launch via=workspace app=%@ ok=%d took=%.1fms",
              bundleID, (int)ok, (CFAbsoluteTimeGetCurrent() - t0) * 1000.0);
    });
}

// 0.4.4: the empty state offers the music apps that are actually installed
// instead of always opening Apple Music. Order is priority order -- the first
// kRBMusicAppMaxShown that exist get a button.
static NSString *const kRBMusicAppIDs[] = {
    @"com.soda.music",         // 汽水音乐
    @"com.netease.cloudmusic", // 网易云音乐
    @"com.tencent.QQMusic",    // QQ 音乐
    @"com.spotify.client",     // Spotify
    @"com.kugou.kugou1002",    // 酷狗音乐
    @"com.apple.Music",        // 音乐 -- last, and only if nothing else is there
};
static NSUInteger const kRBMusicAppCount = sizeof(kRBMusicAppIDs) / sizeof(kRBMusicAppIDs[0]);
// Four keeps the row inside the card at the smallest font size; a fifth starts
// squeezing the label.
static NSUInteger const kRBMusicAppMaxShown = 4;

// 0.4.5: one character per app, used when no icon can be fetched at all. Four
// identical music.note glyphs said nothing -- at a glance the row was four
// blank tiles. A character at least answers "which app does this open".
static NSString *const kRBMusicAppInitials[] = {
    @"汽", @"网", @"Q", @"S", @"酷", @"音",
};
// The two tables are indexed together, so a mismatch is a silent wrong glyph.
_Static_assert(sizeof(kRBMusicAppIDs) / sizeof(kRBMusicAppIDs[0]) ==
               sizeof(kRBMusicAppInitials) / sizeof(kRBMusicAppInitials[0]),
               "kRBMusicAppInitials must stay in step with kRBMusicAppIDs");

@protocol RBAppProxy <NSObject>
@property (nonatomic, readonly) NSString *bundleIdentifier;
// Private and version-dependent -- every call site probes respondsToSelector:
// first. Declared here only so the call is type-checked instead of going
// through performSelector, which would lose the return type under -Werror.
- (BOOL)isInstalled;
- (NSURL *)bundleURL;
- (NSData *)iconData;
- (NSData *)iconDataForVariant:(int)variant;
@end

@interface LSApplicationProxy : NSObject
+ (id<RBAppProxy>)applicationProxyForIdentifier:(NSString *)identifier;
@end

static BOOL rbAppInstalled(NSString *bundleID) {
    Class cls = NSClassFromString(@"LSApplicationProxy");
    if (!cls) return NO;
    id<RBAppProxy> proxy = (id<RBAppProxy>)[(id)cls applicationProxyForIdentifier:bundleID];
    if (!proxy || proxy.bundleIdentifier.length == 0) return NO;

    // 🔴 0.4.5 field log: `com.spotify.client` still produced a tile, and tapping
    // it returned SBS rc=7 with the workspace fallback ok=0 -- the app was not
    // installed at all. LSApplicationProxy answers an UNKNOWN identifier with a
    // lazy placeholder whose -bundleIdentifier simply echoes the query back, so
    // "proxy exists and has an id" proves nothing. Ask the proxy for its own
    // state, then confirm the bundle is actually on disk. Each check only ever
    // vetoes; when an accessor is missing we keep the old, lenient answer so a
    // future iOS cannot make every tile vanish.
    BOOL hasState = [proxy respondsToSelector:@selector(isInstalled)];
    BOOL stateInstalled = hasState ? [proxy isInstalled] : YES;
    BOOL hasURL = [proxy respondsToSelector:@selector(bundleURL)];
    NSURL *url = hasURL ? [proxy bundleURL] : nil;
    BOOL onDisk = (url.path.length == 0)
        ? YES
        : [[NSFileManager defaultManager] fileExistsAtPath:url.path];
    RBLog(@"nowplaying app probe app=%@ hasState=%d state=%d hasURL=%d onDisk=%d",
          bundleID, (int)hasState, (int)stateInstalled, (int)hasURL, (int)onDisk);
    return stateInstalled && onDisk;
}

// The app icon, not the album artwork. Artwork is the fragile corner of
// MediaRemote on iOS 16 -- it is simply not in the info dictionary -- while the
// launch icon is stable, and it answers the more useful question anyway.
@interface UIImage (RBAppIcon)
+ (UIImage *)_applicationIconImageForBundleIdentifier:(NSString *)bundleID format:(int)format;
@end

static NSString *rbMusicAppInitial(NSString *bundleID) {
    for (NSUInteger i = 0; i < kRBMusicAppCount; i++) {
        if ([kRBMusicAppIDs[i] isEqualToString:bundleID]) return kRBMusicAppInitials[i];
    }
    return @"♪";
}

// 🔴 0.4.4 field report: the fourth tile came out blank. A private icon lookup
// does not have to fail loudly -- it can hand back a correctly sized but FULLY
// TRANSPARENT placeholder, which sails past a nil check and then paints
// nothing. So "did I get an image" is the wrong question; the right one is "is
// there a visible pixel in it". The image is rendered down to 1x1 and its alpha
// sampled -- four tiles, once per mount, is not a measurable cost.
static BOOL rbImageHasContent(UIImage *image) {
    if (!image || !image.CGImage) return NO;
    if (image.size.width < 8.0 || image.size.height < 8.0) return NO;
    unsigned char px[4] = {0, 0, 0, 0};
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(px, 1, 1, 8, 4, space,
                                             (uint32_t)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(space);
    if (!ctx) return YES;   // cannot measure, so trust what the lookup returned
    CGContextSetInterpolationQuality(ctx, kCGInterpolationLow);
    CGContextDrawImage(ctx, CGRectMake(0.0, 0.0, 1.0, 1.0), image.CGImage);
    CGContextRelease(ctx);
    return px[3] > 12;
}

static UIImage *rbAppIcon(NSString *bundleID) {
    if (!bundleID.length) return nil;
    // Path 1: the private UIKit lookup. 🔴 Guarded -- an unguarded miss raises
    // unrecognised-selector inside SpringBoard, which is a Safe Mode crash for
    // the sake of a 30pt thumbnail.
    if ([UIImage respondsToSelector:@selector(_applicationIconImageForBundleIdentifier:format:)]) {
        UIImage *img = [UIImage _applicationIconImageForBundleIdentifier:bundleID format:2];
        if (rbImageHasContent(img)) return img;
        RBLog(@"nowplaying icon uikit empty app=%@ size=%.0fx%.0f cg=%d",
              bundleID, img.size.width, img.size.height, (int)(img.CGImage != NULL));
    } else {
        RBLog(@"nowplaying app icon unavailable: selector missing");
    }
    // Path 2: the icon PNG straight out of LaunchServices. This is what covers
    // the bundles UIKit declines to render -- system apps in particular, which is
    // exactly the blank tile that was reported. Both accessors are probed because
    // which of them exists has changed across releases.
    Class cls = NSClassFromString(@"LSApplicationProxy");
    if (cls) {
        id<RBAppProxy> proxy = (id<RBAppProxy>)[(id)cls applicationProxyForIdentifier:bundleID];
        NSData *data = nil;
        if ([proxy respondsToSelector:@selector(iconData)]) data = [proxy iconData];
        if (data.length == 0 && [proxy respondsToSelector:@selector(iconDataForVariant:)]) {
            data = [proxy iconDataForVariant:0];
        }
        if (data.length) {
            UIImage *img = [UIImage imageWithData:data];
            if (rbImageHasContent(img)) {
                RBLog(@"nowplaying icon proxy app=%@ bytes=%lu",
                      bundleID, (unsigned long)data.length);
                return img;
            }
        }
    }
    RBLog(@"nowplaying icon none app=%@", bundleID);
    return nil;
}

#pragma mark - scrubber

// 0.4.2: draggable progress bar.
//
// UIProgressView cannot be dragged -- it is a renderer with no tracking at all,
// so the bar had to become a UIControl. Two decisions worth keeping:
//
//   * touch tracking, NOT a UIPanGestureRecognizer. A recogniser has to win an
//     arbitration round against the Reachability gesture; beginTracking: simply
//     claims the touch before any recogniser sees it.
//   * the control is 22pt tall with a 2pt bar drawn in the middle. The bar is
//     what you see, the 22pt is what a finger can actually hit. That strip is
//     the only part of the card that no longer passes touches through to the
//     Reachability dismiss -- everything else still does.
@interface RBNPScrubber : UIControl
@property (nonatomic, assign) double fraction;
@end

@implementation RBNPScrubber {
    CALayer *_track;
    CALayer *_fill;
    UIView *_knob;
    // Declared here so the custom setter below does not depend on autosynthesis.
    double _fraction;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.tag = kRBScrubberTag;
        self.backgroundColor = [UIColor clearColor];
        self.opaque = NO;

        _track = [CALayer layer];
        _track.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.22].CGColor;
        [self.layer addSublayer:_track];

        _fill = [CALayer layer];
        _fill.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.92].CGColor;
        [self.layer addSublayer:_fill];

        // Only visible while a finger is down: it advertises "this is draggable"
        // exactly when that is useful, and leaves the resting card untouched.
        _knob = [[UIView alloc] initWithFrame:CGRectZero];
        _knob.backgroundColor = [UIColor whiteColor];
        _knob.userInteractionEnabled = NO;
        _knob.hidden = YES;
        [self addSubview:_knob];
    }
    return self;
}

- (void)setFraction:(double)fraction {
    if (!isfinite(fraction)) fraction = 0;
    fraction = MAX(0.0, MIN(1.0, fraction));
    if (fabs(fraction - _fraction) < 0.0005) return;
    _fraction = fraction;
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = CGRectGetWidth(self.bounds);
    CGFloat h = CGRectGetHeight(self.bounds);
    CGFloat barH = 2.0;
    CGFloat y = floor((h - barH) * 0.5);

    // 🔴 The tick rewrites fraction once a second; without this the implicit
    // 0.25s animation makes the bar lag behind the clock and look drunk.
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _track.frame = CGRectMake(0, y, w, barH);
    _track.cornerRadius = barH * 0.5;
    _fill.frame = CGRectMake(0, y, w * _fraction, barH);
    _fill.cornerRadius = barH * 0.5;
    [CATransaction commit];

    _knob.frame = CGRectMake(w * _fraction - 4.0, (h - 8.0) * 0.5, 8.0, 8.0);
    _knob.layer.cornerRadius = 4.0;
}

- (CGFloat)rbFractionAtTouch:(UITouch *)touch {
    CGFloat w = CGRectGetWidth(self.bounds);
    if (w < 1.0) return 0;
    CGPoint p = [touch locationInView:self];
    return MAX(0.0, MIN(1.0, p.x / w));
}

- (BOOL)beginTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    _knob.hidden = NO;
    self.fraction = [self rbFractionAtTouch:touch];
    [self sendActionsForControlEvents:UIControlEventTouchDown];
    [self sendActionsForControlEvents:UIControlEventValueChanged];
    return YES;
}

- (BOOL)continueTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    self.fraction = [self rbFractionAtTouch:touch];
    [self sendActionsForControlEvents:UIControlEventValueChanged];
    return YES;
}

- (void)endTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    if (touch) {
        self.fraction = [self rbFractionAtTouch:touch];
        [self sendActionsForControlEvents:UIControlEventValueChanged];
    }
    _knob.hidden = YES;
    // Sent by hand rather than left to UIKit: whether UIControl fires
    // TouchUpInside itself after endTracking: is not contractual, and a missed
    // event would leave the card's scrubbing flag stuck at YES, which silently
    // freezes the clock. rbScrubEnded: is idempotent, so a duplicate is harmless.
    [self sendActionsForControlEvents:UIControlEventTouchUpInside];
    [super endTrackingWithTouch:touch withEvent:event];
}

- (void)cancelTrackingWithEvent:(UIEvent *)event {
    _knob.hidden = YES;
    // Same reasoning: a lost TouchCancel would strand scrubbing == YES forever.
    [self sendActionsForControlEvents:UIControlEventTouchCancel];
    [super cancelTrackingWithEvent:event];
}

@end

@interface RBNowPlayingCard ()
@property (nonatomic, strong) UIView *view;
@property (nonatomic, strong) UILabel *headerLabel;
@property (nonatomic, strong) UILabel *timeLabel;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *artistLabel;
@property (nonatomic, strong) RBNPScrubber *scrubber;
// Two mutually exclusive faces of the same card: the full transport layout when
// something is playing, and a single 44pt row when nothing is. The empty state
// used to keep the whole card mounted at ~118pt, which on a half-screen
// Reachability panel is a lot of nothing.
// Hidden arranged subviews collapse to zero height, so flipping these six flags
// is the entire switch between the two faces.
@property (nonatomic, strong) UIStackView *headerRow;
@property (nonatomic, strong) UIStackView *titleRow;
@property (nonatomic, strong) UIStackView *emptyRow;
@property (nonatomic, strong) UIImageView *appIconView;
@property (nonatomic, strong) UIStackView *openApps;
/// Bundle ids behind the empty-state buttons, indexed by (button.tag - kRBOpenTag).
@property (nonatomic, copy) NSArray<NSString *> *openTargets;
@property (nonatomic, copy) NSString *sourceBundleID;
// True from touchDown to touchUp on the scrubber. While set the tick and every
// fetch-driven redraw leave elapsed/time/bar alone, otherwise the 1s clock drags
// the bar back out from under the finger.
@property (nonatomic, assign) BOOL scrubbing;
@property (nonatomic, strong) UIView *transportContainer;
@property (nonatomic, strong) UIButton *prevButton;
@property (nonatomic, strong) UIButton *playButton;
@property (nonatomic, strong) UIButton *nextButton;

@property (nonatomic, copy) NSString *trackTitle;
@property (nonatomic, copy) NSString *trackArtist;
@property (nonatomic, assign) double duration;
@property (nonatomic, assign) double elapsed;
@property (nonatomic, assign) BOOL playing;
@property (nonatomic, assign) BOOL hasMedia;
@property (nonatomic, strong) NSTimer *tickTimer;
// -1 = nothing waiting. Set on seek, consumed by the very next fetch so the log
// can state whether the app actually moved.
@property (nonatomic, assign) double pendingSeekTarget;

@property (nonatomic, assign) CGFloat styleOpacity;
@property (nonatomic, assign) CGFloat styleCorner;
@property (nonatomic, assign) CGFloat styleBorder;
@property (nonatomic, assign) BOOL styleCompact;

- (void)buildView;
- (void)rbFetch;
- (void)rbApplyTitle:(NSString *)title artist:(NSString *)artist
            duration:(double)duration elapsed:(double)elapsed playing:(BOOL)playing;
- (void)rbUpdateLabels;
- (void)rbStartTick;
- (void)rbStopTick;
- (void)rbTick;
- (NSString *)rbTimeText:(double)seconds;
- (void)rbSendCommand:(int)command label:(NSString *)label;
- (void)rbSeekTo:(double)seconds;
// 0.4.7: hold prev/next to nudge 15s each way; tap still changes track.
- (BOOL)rbIsLiveBroadcast;
- (void)rbNudgeBy:(double)delta;
- (void)rbPrevLongPress:(UILongPressGestureRecognizer *)sender;
- (void)rbNextLongPress:(UILongPressGestureRecognizer *)sender;
- (void)rbScrubDown:(RBNPScrubber *)sender;
- (void)rbScrubChanged:(RBNPScrubber *)sender;
- (void)rbScrubEnded:(RBNPScrubber *)sender;
- (void)rbScrubCancelled:(RBNPScrubber *)sender;
- (void)rbFetchSourceApp;
- (void)rbApplySourceApp:(NSString *)bundleID;
- (void)rbOpenTargetTapped:(UIButton *)sender;
- (void)rbHaptic:(UIImpactFeedbackStyle)style;
- (void)rbTouchDown:(UIControl *)sender;
- (void)rbTouchCancel:(UIControl *)sender;
- (void)rbScheduleDisarm;
@end

@implementation RBNowPlayingCard

- (instancetype)init {
    self = [super init];
    if (self) {
        // Same defaults as the other two cards so the deck looks like one object.
        _styleOpacity = 0.72;
        _styleCorner = 16;
        _styleBorder = 1;
        _styleCompact = NO;
        // "no pending seek" needs a sentinel that cannot collide with 0 seconds.
        _pendingSeekTarget = -1;
    }
    return self;
}

- (void)dealloc {
    [_tickTimer invalidate];
}

#pragma mark - RBCard

// 150 sits between the privacy card (100) and the clipboard card (200): the
// media card changes most often, so it is worth the second slot.
- (NSInteger)rbPriority { return 150; }
- (NSString *)rbIdentifier { return @"nowplaying"; }
- (NSString *)rbRailImageName { return @"music.note"; }
- (NSString *)rbRailTitle { return @"正在播放"; }

- (UIView *)rbView {
    if (!self.view) {
        [self buildView];
    }
    return self.view;
}

- (void)rbRefresh {
    [self rbFetch];
}

- (void)rbWillUnmount {
    // Hidden cards must not keep a 1s timer alive: the deck keeps up to three
    // cards mounted and this one is only audible when it is the front card.
    [self rbStopTick];
}

- (void)setStyleOpacity:(CGFloat)opacity corner:(CGFloat)corner border:(CGFloat)border compact:(BOOL)compact {
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
    RBLog(@"nowplaying style apply opacity=%.2f corner=%.0f border=%.0f compact=%d",
          opacity, corner, border, (int)compact);
    [self rbStopTick];
    self.view = nil;
    self.headerLabel = nil;
    self.timeLabel = nil;
    self.titleLabel = nil;
    self.artistLabel = nil;
    self.headerRow = nil;
    self.titleRow = nil;
    self.emptyRow = nil;
    self.appIconView = nil;
    self.openApps = nil;
    self.openTargets = nil;
    self.scrubber = nil;
    // A rebuild throws the control away mid-drag only if the style changed from
    // the settings sheet, which cannot happen while a finger is on the card --
    // but the flag must not survive into the new view regardless.
    self.scrubbing = NO;
    self.transportContainer = nil;
    self.prevButton = nil;
    self.playButton = nil;
    self.nextButton = nil;
}

#pragma mark - data

- (void)rbFetch {
    RBNPGetInfoFn getInfo = rbNPGetInfo();
    if (!getInfo) {
        RBLog(@"nowplaying fetch skipped: no MediaRemote");
        return;
    }
    __weak typeof(self) weakSelf = self;
    // Private queue on purpose: MediaRemote answers from its own serial queue and
    // blocking main while it decides would stutter the Reachability animation.
    getInfo(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^(CFDictionaryRef information) {
        // The dictionary is only valid inside this callback, so everything is
        // copied out before hopping back to the main queue.
        NSDictionary *info = (__bridge NSDictionary *)information;
        NSString *title = nil;
        NSString *artist = nil;
        double duration = 0;
        double elapsed = 0;
        BOOL playing = NO;
        if ([info isKindOfClass:[NSDictionary class]]) {
            id t = info[kRBNPTitleKey];
            if ([t isKindOfClass:[NSString class]] && [t length]) title = [t copy];
            id a = info[kRBNPArtistKey];
            if ([a isKindOfClass:[NSString class]] && [a length]) artist = [a copy];
            id d = info[kRBNPDurationKey];
            if ([d isKindOfClass:[NSNumber class]]) duration = [d doubleValue];
            id e = info[kRBNPElapsedKey];
            if ([e isKindOfClass:[NSNumber class]]) elapsed = [e doubleValue];
            id r = info[kRBNPRateKey];
            if ([r isKindOfClass:[NSNumber class]]) playing = ([r doubleValue] > 0.5);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf rbApplyTitle:title artist:artist
                            duration:duration elapsed:elapsed playing:playing];
        });
    });
    // Runs alongside the info fetch: an app that has no now-playing client simply
    // reports none and the thumbnail stays hidden.
    [self rbFetchSourceApp];
}

- (void)rbFetchSourceApp {
    RBNPGetClientFn getClient = rbNPGetClient();
    if (!getClient) {
        RBLog(@"nowplaying source skipped: no MRMediaRemoteGetNowPlayingClient");
        return;
    }
    __weak typeof(self) weakSelf = self;
    getClient(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^(id client) {
        // Same rule as the info dictionary: read on MediaRemote's queue, apply
        // on main. The client object is not touched after this block returns.
        NSString *bundleID = nil;
        id<RBNPClient> c = (id<RBNPClient>)client;
        if ([c respondsToSelector:@selector(bundleIdentifier)]) {
            NSString *b = [c bundleIdentifier];
            if ([b isKindOfClass:[NSString class]] && b.length) bundleID = [b copy];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf rbApplySourceApp:bundleID];
        });
    });
}

- (void)rbApplySourceApp:(NSString *)bundleID {
    BOOL changed = !((bundleID.length == 0 && self.sourceBundleID.length == 0) ||
                     [bundleID isEqualToString:self.sourceBundleID]);
    self.sourceBundleID = bundleID;
    // The client query can land before the first rbView access; buildView
    // re-applies whatever is stored here, so bailing now loses nothing.
    if (!self.appIconView) return;
    if (bundleID.length == 0) {
        self.appIconView.image = nil;
        self.appIconView.hidden = YES;
        if (changed) RBLog(@"nowplaying source app=none");
        return;
    }
    UIImage *icon = rbAppIcon(bundleID);
    if (icon) {
        self.appIconView.image = icon;
        self.appIconView.tintColor = nil;
    } else {
        // Better an SF Symbol than an empty 18pt square: the card keeps its
        // rhythm and still says "some app is playing".
        UIImageSymbolConfiguration *cfg =
            [UIImageSymbolConfiguration configurationWithPointSize:10 weight:UIFontWeightSemibold];
        UIImage *glyph = [[UIImage systemImageNamed:@"music.note" withConfiguration:cfg]
                          imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        self.appIconView.image = glyph;
        self.appIconView.tintColor = [[UIColor whiteColor] colorWithAlphaComponent:0.72];
    }
    self.appIconView.hidden = NO;
    if (changed) RBLog(@"nowplaying source app=%@ realIcon=%d", bundleID, (int)(icon != nil));
}

- (void)rbApplyTitle:(NSString *)title artist:(NSString *)artist
            duration:(double)duration elapsed:(double)elapsed playing:(BOOL)playing {
    self.trackTitle = title;
    self.trackArtist = artist;
    self.duration = duration;
    self.elapsed = elapsed;
    self.playing = playing;
    self.hasMedia = (title.length > 0);
    RBLog(@"nowplaying state media=%d playing=%d elapsed=%.0f duration=%.0f",
          (int)self.hasMedia, (int)playing, elapsed, duration);
    // A seek is only done once the system says so. Playing media drifts forward
    // while the read-back is in flight, hence the deliberately loose 8s window.
    if (self.pendingSeekTarget >= 0) {
        double want = self.pendingSeekTarget;
        self.pendingSeekTarget = -1;
        RBLog(@"nowplaying seek %@ want=%.0f got=%.0f",
              (fabs(elapsed - want) > 8.0) ? @"ignored" : @"confirmed", want, elapsed);
    }
    [self rbUpdateLabels];
    if (self.hasMedia && playing) {
        [self rbStartTick];
    } else {
        [self rbStopTick];
    }
}

- (NSString *)rbTimeText:(double)seconds {
    if (seconds < 0 || !isfinite(seconds)) seconds = 0;
    long total = (long)lround(seconds);
    return [NSString stringWithFormat:@"%ld:%02ld", total / 60, total % 60];
}

- (void)rbUpdateLabels {
    if (!self.view) return;
    BOOL has = self.hasMedia;
    self.titleLabel.text = has ? self.trackTitle : @"没有正在播放的内容";
    self.titleLabel.textColor = [[UIColor whiteColor] colorWithAlphaComponent:(has ? 0.95 : 0.55)];
    self.artistLabel.text = has ? (self.trackArtist.length ? self.trackArtist : @"未知艺术家")
                                : @"播放音乐或播客后会显示";
    // While a finger is on the scrubber the clock and the bar belong to the
    // finger -- not to the 1s tick, and not to an in-flight fetch that landed
    // mid-drag. Everything else on the card still refreshes as usual.
    BOOL live = [self rbIsLiveBroadcast];
    if (!self.scrubbing) {
        // 0.4.7: a live stream has no length, so "elapsed / duration" used to read
        // "0:12 / 0:00" -- two numbers that contradict each other. Show what is
        // actually known: how long it has been on.
        if (live) {
            self.timeLabel.text = [NSString stringWithFormat:@"直播 · %@",
                                   [self rbTimeText:self.elapsed]];
        } else if (has) {
            self.timeLabel.text = [NSString stringWithFormat:@"%@ / %@",
                                   [self rbTimeText:self.elapsed], [self rbTimeText:self.duration]];
        } else {
            self.timeLabel.text = @"";
        }
        double frac = 0;
        if (has && !live && self.duration > 1) {
            frac = self.elapsed / self.duration;
            if (frac < 0) frac = 0;
            if (frac > 1) frac = 1;
        }
        self.scrubber.fraction = frac;
    }
    // A live stream has nothing to scrub to, and an empty bar under "LIVE" invites
    // a drag that can never work. Hiding it also drops 22pt of card height, which
    // is the honest size for a row that no longer has a bar.
    self.scrubber.hidden = (!has || live);
    // With nothing playing -- or a track whose length is still unknown -- a drag
    // would move the bar with nowhere to seek to. Refusing the touch outright is
    // cleaner than accepting it and bailing out inside every handler.
    self.scrubber.userInteractionEnabled = (has && !live && self.duration > 1);
    self.playButton.enabled = has;
    self.prevButton.enabled = has;
    self.nextButton.enabled = has;
    self.transportContainer.alpha = has ? 1.0 : 0.32;
    // 🔴 Two faces, one card. Hiding an arranged subview collapses it to zero
    // height (and drops its spacing), so the card resizes itself -- there is no
    // constraint to flip and no height constant to keep in sync.
    self.headerRow.hidden = !has;
    self.titleRow.hidden = !has;
    self.artistLabel.hidden = !has;
    self.transportContainer.hidden = !has;
    self.emptyRow.hidden = has;
    NSString *symbol = self.playing ? @"pause.fill" : @"play.fill";
    UIImageSymbolConfiguration *cfg =
        [UIImageSymbolConfiguration configurationWithPointSize:15 weight:UIFontWeightSemibold];
    [self.playButton setImage:[UIImage systemImageNamed:symbol withConfiguration:cfg]
                     forState:UIControlStateNormal];
}

#pragma mark - tick

- (void)rbStartTick {
    if (self.tickTimer) return;
    if (!self.hasMedia || !self.playing) return;
    __weak typeof(self) weakSelf = self;
    self.tickTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *timer) {
        (void)timer;
        __strong typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf rbTick];
    }];
    RBLog(@"nowplaying tick start");
}

- (void)rbStopTick {
    if (!self.tickTimer) return;
    [self.tickTimer invalidate];
    self.tickTimer = nil;
    RBLog(@"nowplaying tick stop");
}

- (void)rbTick {
    if (!self.hasMedia) {
        [self rbStopTick];
        return;
    }
    // A finger on the bar owns elapsed; advancing it here would fight the finger.
    if (self.scrubbing) return;
    // Paused media keeps reporting a rate of 0, so the timer would just sit
    // there advancing nothing -- stop it and let the next rbRefresh restart it.
    if (!self.playing) {
        [self rbStopTick];
        return;
    }
    self.elapsed += 1.0;
    if (self.duration > 1 && self.elapsed > self.duration) {
        // Track ran out; the authoritative elapsed time comes from the next fetch.
        self.elapsed = self.duration;
        [self rbUpdateLabels];
        [self rbStopTick];
        [self rbFetch];
        return;
    }
    [self rbUpdateLabels];
}

#pragma mark - transport

- (void)rbSendCommand:(int)command label:(NSString *)label {
    RBNPSendFn send = rbNPSendCommand();
    if (!send) {
        RBLog(@"nowplaying send skipped: no MediaRemote");
        return;
    }
    Boolean ok = send(command, NULL);
    RBLog(@"nowplaying send cmd=%d ok=%d (%@)", command, (int)ok, label);
    // MediaRemote answers asynchronously, so re-read a beat later instead of
    // flipping local state and hoping it agrees.
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf rbFetch];
    });
}

- (void)rbPrevTapped:(UIButton *)sender {
    (void)sender;
    [self rbHaptic:UIImpactFeedbackStyleLight];
    [self rbSendCommand:kRBCmdPreviousTrack label:@"prev"];
    [self rbScheduleDisarm];
}

- (void)rbPlayPauseTapped:(UIButton *)sender {
    (void)sender;
    [self rbHaptic:UIImpactFeedbackStyleLight];
    [self rbSendCommand:kRBCmdTogglePlayPause label:@"toggle"];
    [self rbScheduleDisarm];
}

- (void)rbNextTapped:(UIButton *)sender {
    (void)sender;
    [self rbHaptic:UIImpactFeedbackStyleLight];
    [self rbSendCommand:kRBCmdNextTrack label:@"next"];
    [self rbScheduleDisarm];
}

#pragma mark - scrub

- (void)rbScrubDown:(RBNPScrubber *)sender {
    (void)sender;
    if (!self.hasMedia || self.duration <= 1) return;
    // 🔴 UIControl sends TouchDown from touchesBegan, and the scrubber sends one
    // by hand as well so that a missed system event cannot strand the drag. The
    // result is two deliveries per touch (0.4.3 log: "scrub down" twice, 4ms
    // apart). The guard keeps the second one from re-arming and re-logging.
    if (self.scrubbing) return;
    self.scrubbing = YES;
    // Same rule as the transport buttons: arm before the dismiss callback can
    // land, which on a drag happens long before any touch-up.
    RBPrivacyArmInteraction();
    RBLog(@"nowplaying scrub down");
}

- (void)rbScrubChanged:(RBNPScrubber *)sender {
    if (!self.scrubbing || self.duration <= 1) return;
    // The clock has to follow the finger too, otherwise the bar moves while the
    // numbers sit still and the drag reads as broken.
    double at = self.duration * sender.fraction;
    self.timeLabel.text = [NSString stringWithFormat:@"%@ / %@",
                           [self rbTimeText:at], [self rbTimeText:self.duration]];
}

- (void)rbScrubCancelled:(RBNPScrubber *)sender {
    (void)sender;
    // TouchCancel also arrives twice (touchesCancelled plus the by-hand send in
    // cancelTrackingWithEvent:), so the second delivery must be a no-op.
    if (!self.scrubbing) return;
    // TouchCancel means the system took the touch away (incoming call, gesture
    // arbitration): drop the drag and redraw from the real elapsed time.
    self.scrubbing = NO;
    [self rbUpdateLabels];
    [self rbScheduleDisarm];
    RBLog(@"nowplaying scrub cancel");
}

- (void)rbScrubEnded:(RBNPScrubber *)sender {
    if (!self.scrubbing) return;
    self.scrubbing = NO;
    if (self.duration <= 1) {
        [self rbUpdateLabels];
        [self rbScheduleDisarm];
        return;
    }
    double target = self.duration * sender.fraction;
    [self rbHaptic:UIImpactFeedbackStyleRigid];
    RBLog(@"nowplaying scrub end fraction=%.3f target=%.0f", sender.fraction, target);
    [self rbSeekTo:target];
    [self rbScheduleDisarm];
}

- (void)rbSeekTo:(double)seconds {
    RBNPSendFn send = rbNPSendCommand();
    if (!send) {
        RBLog(@"nowplaying seek skipped: no MediaRemote");
        return;
    }
    if (!isfinite(seconds) || seconds < 0) seconds = 0;
    if (self.duration > 1 && seconds > self.duration) seconds = self.duration;

    NSDictionary *info = @{ kRBOptionPlaybackPosition: @(seconds) };
    Boolean ok = send(kRBCmdSeekToPlaybackPosition, (__bridge CFDictionaryRef)info);
    RBLog(@"nowplaying seek to=%.1f ok=%d", seconds, (int)ok);

    // Optimistic on purpose: the bar has to stay where the finger left it. The
    // read-back a beat later is the truth, and rbApplyTitle: compares the two so
    // an app that accepts the command and silently ignores it is visible in the
    // log instead of looking like a dead slider.
    self.elapsed = seconds;
    [self rbUpdateLabels];
    self.pendingSeekTarget = seconds;

    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf rbFetch];
    });
}

- (BOOL)rbIsLiveBroadcast {
    // MediaRemote has no "live" flag: a stream simply reports no duration. So the
    // missing length IS the signal, and the test stays blunt on purpose -- a real
    // track shorter than a second does not exist.
    return (self.hasMedia && self.duration <= 1.0);
}

- (void)rbNudgeBy:(double)delta {
    if (!self.hasMedia || [self rbIsLiveBroadcast]) return;
    double from = self.elapsed;
    double target = from + delta;
    if (target < 0) target = 0;
    if (target > self.duration) target = self.duration;
    // A medium tap, distinct from the light one a track change makes: the only
    // feedback that a hold did something is this and the bar jumping.
    [self rbHaptic:UIImpactFeedbackStyleMedium];
    RBLog(@"nowplaying nudge delta=%.0f from=%.0f to=%.0f", delta, from, target);
    [self rbSeekTo:target];
    [self rbScheduleDisarm];
}

- (void)rbPrevLongPress:(UILongPressGestureRecognizer *)sender {
    // Only Began: a hold fires once, on recognition, not again on Ended.
    if (sender.state != UIGestureRecognizerStateBegan) return;
    [self rbNudgeBy:-15.0];
}

- (void)rbNextLongPress:(UILongPressGestureRecognizer *)sender {
    if (sender.state != UIGestureRecognizerStateBegan) return;
    [self rbNudgeBy:15.0];
}

- (void)rbHaptic:(UIImpactFeedbackStyle)style {
    // One tick, generated on demand. The panel is a short deliberate gesture --
    // a light tap should feel like a tap, not like a game controller.
    UIImpactFeedbackGenerator *gen = [[UIImpactFeedbackGenerator alloc] initWithStyle:style];
    [gen impactOccurred];
}

- (void)rbOpenTargetTapped:(UIButton *)sender {
    NSInteger idx = sender.tag - kRBOpenTag;
    if (idx < 0 || (NSUInteger)idx >= self.openTargets.count) return;
    NSString *bundleID = self.openTargets[(NSUInteger)idx];
    [self rbHaptic:UIImpactFeedbackStyleLight];
    // The whole reason Reachability exists is that the top of the screen is out
    // of reach; the empty card should be a way into music, not a dead end -- and
    // into the app the user actually listens with, not the one we guessed.
    RBLog(@"nowplaying open target idx=%ld app=%@", (long)idx, bundleID);
    rbOpenApp(bundleID);
    [self rbScheduleDisarm];
}

// Same rule as the other cards: arm the dismiss suppression on touchDown,
// because SpringBoard's dismiss callback can land before touchUpInside.
- (void)rbTouchDown:(UIControl *)sender {
    (void)sender;
    RBPrivacyArmInteraction();
    RBLog(@"nowplaying touch down");
}

- (void)rbTouchCancel:(UIControl *)sender {
    (void)sender;
    [self rbScheduleDisarm];
}

- (void)rbScheduleDisarm {
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        RBPrivacyCancelInteraction();
    });
}

#pragma mark - view

- (UIButton *)rbTransportButton:(NSString *)symbol action:(SEL)action {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.translatesAutoresizingMaskIntoConstraints = NO;
    b.tag = kRBTransportTag;
    b.tintColor = [[UIColor whiteColor] colorWithAlphaComponent:0.92];
    // No showsTouchWhenHighlighted: it is deprecated as of iOS 15 and this build
    // runs with -Werror.
    UIImageSymbolConfiguration *cfg =
        [UIImageSymbolConfiguration configurationWithPointSize:15 weight:UIFontWeightSemibold];
    [b setImage:[UIImage systemImageNamed:symbol withConfiguration:cfg] forState:UIControlStateNormal];
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [b addTarget:self action:@selector(rbTouchDown:) forControlEvents:UIControlEventTouchDown];
    [b addTarget:self action:@selector(rbTouchCancel:)
        forControlEvents:(UIControlEventTouchCancel |
                          UIControlEventTouchUpOutside |
                          UIControlEventTouchDragExit)];
    [b.widthAnchor constraintEqualToConstant:40].active = YES;
    [b.heightAnchor constraintEqualToConstant:34].active = YES;
    return b;
}

- (void)buildView {
    CGFloat pad = _styleCompact ? 10 : 14;
    CGFloat gap = _styleCompact ? 4 : 6;

    UIView *root = [[UIView alloc] initWithFrame:CGRectZero];
    root.translatesAutoresizingMaskIntoConstraints = NO;
    root.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:_styleOpacity];
    root.layer.cornerRadius = _styleCorner;
    root.layer.cornerCurve = kCACornerCurveContinuous;
    root.layer.borderWidth = _styleBorder;
    root.layer.borderColor = [[UIColor whiteColor] colorWithAlphaComponent:0.75].CGColor;
    root.clipsToBounds = YES;
    // No tag on the root on purpose: the card body must stay transparent to
    // touches so the Reachability dismiss gesture still works inside the card.
    // Only the transport buttons carry 'RDB6', and only they swallow.
    root.userInteractionEnabled = YES;
    [root setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisVertical];
    [root setContentCompressionResistancePriority:UILayoutPriorityRequired
                                          forAxis:UILayoutConstraintAxisVertical];
    self.view = root;

    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = gap;
    stack.alignment = UIStackViewAlignmentFill;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    // 🔴 The stack must stay touch-enabled: hitTest: bails out on an ancestor
    // with userInteractionEnabled == NO, which would make the transport buttons
    // unreachable. The clipboard card gets away with NO only because it has no
    // interactive subviews. The stack itself is untagged, so a touch that lands
    // on empty card space still falls through to the Reachability dismiss.
    [root addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:pad],
        [stack.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-pad],
        [stack.topAnchor constraintEqualToAnchor:root.topAnchor constant:pad],
        [root.heightAnchor constraintEqualToAnchor:stack.heightAnchor constant:pad * 2],
        [stack.heightAnchor constraintGreaterThanOrEqualToConstant:36],
    ]];

    UIStackView *headerRow = [[UIStackView alloc] init];
    headerRow.axis = UILayoutConstraintAxisHorizontal;
    headerRow.alignment = UIStackViewAlignmentCenter;
    headerRow.spacing = 8;
    headerRow.userInteractionEnabled = NO;
    self.headerRow = headerRow;

    self.headerLabel = [[UILabel alloc] init];
    self.headerLabel.text = @"正在播放";
    self.headerLabel.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.55];
    self.headerLabel.font = [UIFont systemFontOfSize:(_styleCompact ? 10 : 11) weight:UIFontWeightSemibold];
    self.headerLabel.userInteractionEnabled = NO;
    [self.headerLabel setContentHuggingPriority:UILayoutPriorityRequired
                                        forAxis:UILayoutConstraintAxisHorizontal];
    [headerRow addArrangedSubview:self.headerLabel];

    self.timeLabel = [[UILabel alloc] init];
    self.timeLabel.textAlignment = NSTextAlignmentRight;
    self.timeLabel.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.62];
    // Monospaced digits: the elapsed clock ticks every second and a proportional
    // font makes the whole line twitch.
    self.timeLabel.font = [UIFont monospacedDigitSystemFontOfSize:11 weight:UIFontWeightRegular];
    self.timeLabel.userInteractionEnabled = NO;
    [self.timeLabel setContentCompressionResistancePriority:UILayoutPriorityDefaultLow
                                                    forAxis:UILayoutConstraintAxisHorizontal];
    [headerRow addArrangedSubview:self.timeLabel];
    [stack addArrangedSubview:headerRow];

    // Title row carries the source-app icon on the left. The icon needs a fixed
    // size: inside a horizontal stack a flexible label will happily squash an
    // image view to zero width (the same trap the deck's pill glyph hit).
    self.appIconView = [[UIImageView alloc] initWithFrame:CGRectZero];
    self.appIconView.translatesAutoresizingMaskIntoConstraints = NO;
    self.appIconView.contentMode = UIViewContentModeScaleAspectFit;
    self.appIconView.layer.cornerRadius = 4.0;
    self.appIconView.layer.cornerCurve = kCACornerCurveContinuous;
    self.appIconView.clipsToBounds = YES;
    self.appIconView.userInteractionEnabled = NO;
    self.appIconView.hidden = YES;
    [self.appIconView.widthAnchor constraintEqualToConstant:18].active = YES;
    [self.appIconView.heightAnchor constraintEqualToConstant:18].active = YES;
    [self.appIconView setContentHuggingPriority:UILayoutPriorityRequired
                                        forAxis:UILayoutConstraintAxisHorizontal];

    self.titleLabel = [[UILabel alloc] init];
    self.titleLabel.numberOfLines = 1;
    self.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    self.titleLabel.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.95];
    self.titleLabel.font = [UIFont systemFontOfSize:(_styleCompact ? 13 : 14) weight:UIFontWeightSemibold];
    self.titleLabel.userInteractionEnabled = NO;

    UIStackView *titleRow = [[UIStackView alloc] init];
    titleRow.axis = UILayoutConstraintAxisHorizontal;
    titleRow.alignment = UIStackViewAlignmentCenter;
    titleRow.spacing = 7;
    self.titleRow = titleRow;
    [titleRow addArrangedSubview:self.appIconView];
    [titleRow addArrangedSubview:self.titleLabel];
    [stack addArrangedSubview:titleRow];

    self.artistLabel = [[UILabel alloc] init];
    self.artistLabel.numberOfLines = 1;
    self.artistLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    self.artistLabel.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.55];
    self.artistLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightRegular];
    self.artistLabel.userInteractionEnabled = NO;
    [stack addArrangedSubview:self.artistLabel];

    self.scrubber = [[RBNPScrubber alloc] initWithFrame:CGRectZero];
    self.scrubber.translatesAutoresizingMaskIntoConstraints = NO;
    // 22pt of finger target around a 2pt bar.
    [self.scrubber.heightAnchor constraintEqualToConstant:22.0].active = YES;
    [self.scrubber addTarget:self action:@selector(rbScrubDown:)
            forControlEvents:UIControlEventTouchDown];
    [self.scrubber addTarget:self action:@selector(rbScrubChanged:)
            forControlEvents:UIControlEventValueChanged];
    [self.scrubber addTarget:self action:@selector(rbScrubEnded:)
            forControlEvents:(UIControlEventTouchUpInside | UIControlEventTouchUpOutside)];
    [self.scrubber addTarget:self action:@selector(rbScrubCancelled:)
            forControlEvents:UIControlEventTouchCancel];
    [stack addArrangedSubview:self.scrubber];
    // Those extra 20pt are finger target, not layout: collapse the gaps on both
    // sides so the card grows by ~8pt instead of 20 while the visible breathing
    // room around the bar stays roughly what it was.
    [stack setCustomSpacing:0 afterView:self.artistLabel];
    [stack setCustomSpacing:0 afterView:self.scrubber];

    // Wrapper so the transport group can be centred: the vertical stack fills
    // its arranged subviews, which would spread three buttons edge to edge.
    self.transportContainer = [[UIView alloc] initWithFrame:CGRectZero];
    self.transportContainer.translatesAutoresizingMaskIntoConstraints = NO;
    self.transportContainer.userInteractionEnabled = YES;
    [stack addArrangedSubview:self.transportContainer];

    UIStackView *transport = [[UIStackView alloc] init];
    transport.axis = UILayoutConstraintAxisHorizontal;
    transport.alignment = UIStackViewAlignmentCenter;
    transport.spacing = 26;
    transport.translatesAutoresizingMaskIntoConstraints = NO;
    [self.transportContainer addSubview:transport];

    self.prevButton = [self rbTransportButton:@"backward.fill" action:@selector(rbPrevTapped:)];
    self.playButton = [self rbTransportButton:@"play.fill" action:@selector(rbPlayPauseTapped:)];
    self.nextButton = [self rbTransportButton:@"forward.fill" action:@selector(rbNextTapped:)];
    [transport addArrangedSubview:self.prevButton];
    [transport addArrangedSubview:self.playButton];
    [transport addArrangedSubview:self.nextButton];

    // 🔴 0.4.7: a long-press recogniser is allowed HERE even though this project
    // avoids them elsewhere (the scrubber uses raw touch tracking on purpose).
    // The reason is that a hold has no translation, so it never enters the
    // dismissal gesture's arbitration -- there is no slide to lose it to.
    // cancelsTouchesInView keeps its default YES, and that is what makes the
    // split work: a recognised hold cancels the button's touch-up, so a hold can
    // never ALSO change the track. delaysTouchesEnded is off so a plain tap is
    // not held back by half a second while the recogniser waits to fail.
    UILongPressGestureRecognizer *prevHold =
        [[UILongPressGestureRecognizer alloc] initWithTarget:self
                                                      action:@selector(rbPrevLongPress:)];
    prevHold.minimumPressDuration = 0.5;
    prevHold.delaysTouchesEnded = NO;
    [self.prevButton addGestureRecognizer:prevHold];
    UILongPressGestureRecognizer *nextHold =
        [[UILongPressGestureRecognizer alloc] initWithTarget:self
                                                      action:@selector(rbNextLongPress:)];
    nextHold.minimumPressDuration = 0.5;
    nextHold.delaysTouchesEnded = NO;
    [self.nextButton addGestureRecognizer:nextHold];

    [NSLayoutConstraint activateConstraints:@[
        [transport.centerXAnchor constraintEqualToAnchor:self.transportContainer.centerXAnchor],
        [transport.centerYAnchor constraintEqualToAnchor:self.transportContainer.centerYAnchor],
        [transport.topAnchor constraintEqualToAnchor:self.transportContainer.topAnchor],
        [transport.bottomAnchor constraintEqualToAnchor:self.transportContainer.bottomAnchor],
    ]];

    // Empty state: one 44pt row instead of a ~118pt card of nothing. Every other
    // arranged subview collapses to zero height when hidden, so the same stack
    // serves both faces and no constraint ever has to be flipped.
    UIStackView *empty = [[UIStackView alloc] init];
    empty.axis = UILayoutConstraintAxisHorizontal;
    empty.alignment = UIStackViewAlignmentCenter;
    empty.spacing = 8;
    empty.translatesAutoresizingMaskIntoConstraints = NO;
    empty.hidden = YES;
    [empty.heightAnchor constraintEqualToConstant:44].active = YES;
    [stack addArrangedSubview:empty];
    self.emptyRow = empty;

    UIImageSymbolConfiguration *noteCfg =
        [UIImageSymbolConfiguration configurationWithPointSize:13 weight:UIFontWeightMedium];
    UIImageView *note = [[UIImageView alloc] initWithImage:
                         [UIImage systemImageNamed:@"music.note" withConfiguration:noteCfg]];
    note.tintColor = [[UIColor whiteColor] colorWithAlphaComponent:0.55];
    note.contentMode = UIViewContentModeCenter;
    note.userInteractionEnabled = NO;
    note.translatesAutoresizingMaskIntoConstraints = NO;
    [note.widthAnchor constraintEqualToConstant:15].active = YES;
    [note.heightAnchor constraintEqualToConstant:15].active = YES;
    [note setContentHuggingPriority:UILayoutPriorityRequired
                            forAxis:UILayoutConstraintAxisHorizontal];
    [empty addArrangedSubview:note];

    UILabel *emptyLabel = [[UILabel alloc] init];
    emptyLabel.text = @"没有正在播放的内容";
    emptyLabel.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.62];
    emptyLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
    emptyLabel.userInteractionEnabled = NO;
    // Low hugging on purpose: the label absorbs the slack so the button sits at
    // the trailing edge instead of floating in the middle.
    [emptyLabel setContentHuggingPriority:UILayoutPriorityDefaultLow
                                  forAxis:UILayoutConstraintAxisHorizontal];
    [empty addArrangedSubview:emptyLabel];

    // 0.4.4: one button per installed music app. A single "open music" button
    // has to pick an app on the user's behalf, and it picked the wrong one --
    // Apple Music is the least likely choice for anyone who installed a
    // third-party player. Capped at four so the label never gets squeezed.
    NSMutableArray<NSString *> *targets = [NSMutableArray array];
    for (NSUInteger i = 0; i < kRBMusicAppCount && targets.count < kRBMusicAppMaxShown; i++) {
        if (rbAppInstalled(kRBMusicAppIDs[i])) [targets addObject:kRBMusicAppIDs[i]];
    }
    if (targets.count == 0) [targets addObject:kRBAppleMusicBundleID];
    self.openTargets = targets;

    UIStackView *apps = [[UIStackView alloc] init];
    apps.axis = UILayoutConstraintAxisHorizontal;
    apps.alignment = UIStackViewAlignmentCenter;
    apps.spacing = 10.0;
    apps.translatesAutoresizingMaskIntoConstraints = NO;
    [apps setContentHuggingPriority:UILayoutPriorityRequired
                            forAxis:UILayoutConstraintAxisHorizontal];
    for (NSUInteger i = 0; i < targets.count; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
        b.translatesAutoresizingMaskIntoConstraints = NO;
        // 'RDB8' + index: the hitTest bridge accepts the whole 0x52444238..3D band.
        b.tag = kRBOpenTag + (NSInteger)i;
        // The launch icon from _applicationIconImageForBundleIdentifier: comes
        // back square, so the rounding is ours to draw -- 6.75 is 22.5% of 30,
        // which is the radius iOS uses on its own home screen icons.
        b.layer.cornerRadius = 6.75;
        b.layer.cornerCurve = kCACornerCurveContinuous;
        b.clipsToBounds = YES;
        UIImage *icon = rbAppIcon(targets[i]);
        if (icon) {
            // Background image scales to fill, which is what a 30pt tile wants.
            [b setBackgroundImage:icon forState:UIControlStateNormal];
        } else {
            // 0.4.5: the fallback used to be a shared music.note glyph, so every
            // icon-less tile looked the same and the row read as blank. One
            // character per app is carried instead -- it is the last line of
            // defence, not the plan.
            [b setTitle:rbMusicAppInitial(targets[i]) forState:UIControlStateNormal];
            b.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
            [b setTitleColor:[[UIColor whiteColor] colorWithAlphaComponent:0.92]
                    forState:UIControlStateNormal];
            b.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.18];
        }
        // Self-evidence: which tiles got a real icon, and which one did not, so a
        // report can be matched to a tile position without guessing which apps
        // are installed.
        RBLog(@"nowplaying empty tile idx=%lu app=%@ icon=%d",
              (unsigned long)i, targets[i], (int)(icon != nil));
        [b addTarget:self action:@selector(rbOpenTargetTapped:)
    forControlEvents:UIControlEventTouchUpInside];
        [b addTarget:self action:@selector(rbTouchDown:)
    forControlEvents:UIControlEventTouchDown];
        [b addTarget:self action:@selector(rbTouchCancel:)
    forControlEvents:(UIControlEventTouchCancel |
                      UIControlEventTouchUpOutside |
                      UIControlEventTouchDragExit)];
        [b.widthAnchor constraintEqualToConstant:30].active = YES;
        [b.heightAnchor constraintEqualToConstant:30].active = YES;
        [apps addArrangedSubview:b];
    }
    self.openApps = apps;
    [empty addArrangedSubview:apps];
    RBLog(@"nowplaying empty targets=%lu (%@)", (unsigned long)targets.count,
          [targets componentsJoinedByString:@","]);

    // A style change rebuilds the whole view; the card must not forget what is
    // playing just because the outline width moved. State lives in the card,
    // the view only renders it -- including which app is playing.
    if (self.sourceBundleID.length) [self rbApplySourceApp:self.sourceBundleID];
    [self rbUpdateLabels];
    if (self.hasMedia) [self rbStartTick];
}

@end
