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

@interface RBNowPlayingCard ()
@property (nonatomic, strong) UIView *view;
@property (nonatomic, strong) UILabel *headerLabel;
@property (nonatomic, strong) UILabel *timeLabel;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *artistLabel;
@property (nonatomic, strong) UIProgressView *progressView;
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
    self.progressView = nil;
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
    self.timeLabel.text = has ? [NSString stringWithFormat:@"%@ / %@",
                                 [self rbTimeText:self.elapsed], [self rbTimeText:self.duration]]
                              : @"";
    if (has && self.duration > 1) {
        double frac = self.elapsed / self.duration;
        if (frac < 0) frac = 0;
        if (frac > 1) frac = 1;
        [self.progressView setProgress:(float)frac animated:NO];
    } else {
        [self.progressView setProgress:0.0 animated:NO];
    }
    self.progressView.hidden = !has;
    self.playButton.enabled = has;
    self.prevButton.enabled = has;
    self.nextButton.enabled = has;
    self.transportContainer.alpha = has ? 1.0 : 0.32;
    NSString *symbol = self.playing ? @"pause.fill" : @"play.fill";
    UIImageSymbolConfiguration *cfg =
        [UIImageSymbolConfiguration configurationWithPointSize:15 weight:UIImageFontWeightSemibold];
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
    [self rbSendCommand:kRBCmdPreviousTrack label:@"prev"];
    [self rbScheduleDisarm];
}

- (void)rbPlayPauseTapped:(UIButton *)sender {
    (void)sender;
    [self rbSendCommand:kRBCmdTogglePlayPause label:@"toggle"];
    [self rbScheduleDisarm];
}

- (void)rbNextTapped:(UIButton *)sender {
    (void)sender;
    [self rbSendCommand:kRBCmdNextTrack label:@"next"];
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
        [UIImageSymbolConfiguration configurationWithPointSize:15 weight:UIImageFontWeightSemibold];
    [b setImage:[UIImage systemImageNamed:symbol withConfiguration:cfg] forState:UIControlStateNormal];
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [b addTarget:self action:@selector(rbTouchDown:) forControlEvents:UIControlEventTouchDown];
    [b addTarget:self action:@selector(rbTouchCancel:)
        forControlEvents:(UIControlEventTouchCancel |
                          UIControlEventTouchUpOutside |
                          UIControlEventTouchDragExit)];
    [b.widthAnchor constraintEqualToConstant:34].active = YES;
    [b.heightAnchor constraintEqualToConstant:30].active = YES;
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

    self.titleLabel = [[UILabel alloc] init];
    self.titleLabel.numberOfLines = 1;
    self.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    self.titleLabel.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.95];
    self.titleLabel.font = [UIFont systemFontOfSize:(_styleCompact ? 13 : 14) weight:UIFontWeightSemibold];
    self.titleLabel.userInteractionEnabled = NO;
    [stack addArrangedSubview:self.titleLabel];

    self.artistLabel = [[UILabel alloc] init];
    self.artistLabel.numberOfLines = 1;
    self.artistLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    self.artistLabel.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.55];
    self.artistLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightRegular];
    self.artistLabel.userInteractionEnabled = NO;
    [stack addArrangedSubview:self.artistLabel];

    self.progressView = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    self.progressView.translatesAutoresizingMaskIntoConstraints = NO;
    self.progressView.progressTintColor = [[UIColor whiteColor] colorWithAlphaComponent:0.92];
    self.progressView.trackTintColor = [[UIColor whiteColor] colorWithAlphaComponent:0.22];
    self.progressView.userInteractionEnabled = NO;
    [self.progressView.heightAnchor constraintEqualToConstant:2.0].active = YES;
    [stack addArrangedSubview:self.progressView];

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

    [NSLayoutConstraint activateConstraints:@[
        [transport.centerXAnchor constraintEqualToAnchor:self.transportContainer.centerXAnchor],
        [transport.centerYAnchor constraintEqualToAnchor:self.transportContainer.centerYAnchor],
        [transport.topAnchor constraintEqualToAnchor:self.transportContainer.topAnchor],
        [transport.bottomAnchor constraintEqualToAnchor:self.transportContainer.bottomAnchor],
    ]];

    // A style change rebuilds the whole view; the card must not forget what is
    // playing just because the outline width moved. State lives in the card,
    // the view only renders it.
    [self rbUpdateLabels];
    if (self.hasMedia) [self rbStartTick];
}

@end
