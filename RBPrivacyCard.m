#import "RBPrivacyCard.h"
#import <objc/runtime.h>

// ---- Private SpringBoard interfaces (runtime-verified from iOS 17/18 headers) ----
// We deliberately do NOT declare a hardcoded sensor enum: its numeric values are not
// stable across iOS versions. Instead we read the semantic property and fall back to
// the attribution's description. This is the "don't guess the API" rule in code form.
@protocol RBAttribution <NSObject>
- (NSString *)bundleIdentifier;
- (NSString *)displayName;
- (NSString *)activeEntityBundleIdentifier;
- (long long)sensor;
- (BOOL)isSystemService;
- (BOOL)usedRecently;
@end

@interface RBPrivacyCard ()
@property (nonatomic, strong) UIView *view;
@property (nonatomic, strong) UIStackView *contentStack;
@property (nonatomic, strong) UILabel *emptyLabel;
@property (nonatomic, strong) NSArray<NSDictionary *> *rows; // {name, bundle, kind}
@property (nonatomic, assign) BOOL hideSystemServices;
@property (nonatomic, strong) NSSet *lastAttributions;
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
        _rows = @[];
        // SAFE MODE FIX (0.0.2): never touch UIKit here. A card can be created
        // while dyld is still running tweak initializers, before UIApplication is
        // initialized. UIView / Auto Layout calls at that point throw an
        // uncaught NSException from UIKitCore and abort SpringBoard. Keep this
        // object state-only; the UI is built lazily from -rbView, which is only
        // reached after SBReachabilityBackgroundViewController viewWillAppear.
    }
    return self;
}

#pragma mark - RBCard

- (UIView *)rbView {
    // Lazy UI construction: first real access happens inside addRBContainer,
    // i.e. on the main thread with UIApplication fully up.
    if (!self.view) {
        [self buildView];
        [self renderRows]; // reflect sensor data ingested before the UI existed
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
    [self ingestAttributions:self.lastAttributions];
}

- (void)ingestAttributions:(NSSet *)attributions {
    self.lastAttributions = attributions;
    NSMutableArray *out = [NSMutableArray array];
    for (id obj in attributions) {
        if (![obj conformsToProtocol:@protocol(RBAttribution)]) continue;

        id<RBAttribution> a = (id<RBAttribution>)obj;
        NSString *bundle = a.bundleIdentifier ?: a.activeEntityBundleIdentifier ?: @"";
        NSString *name = a.displayName ?: bundle;
        if (name.length == 0) continue;

        // System services are real attributions but usually not what "which app is
        // listening" means. Mark them; optionally filter per preference.
        BOOL system = a.isSystemService;
        if (self.hideSystemServices && system) continue;

        // sensor value semantics: 1 == camera, 2 == microphone on the builds examined.
        // Rather than trust the raw number, derive kind from the class of data we were
        // handed: activeCameraAndMicrophoneActivityAttributions mixes both, so use the
        // numeric hint ONLY as a hint and keep the raw value for the log.
        long long sensor = a.sensor;
        NSString *kind = (sensor == 1) ? @"camera" : (sensor == 2) ? @"microphone" : @"sensor";

        [out addObject:@{ @"name": name, @"bundle": bundle, @"kind": kind,
                          @"system": @(system), @"raw": @(sensor) }];
    }
    self.rows = [out copy];
    [self renderRows];
}

#pragma mark - view

- (void)buildView {
    // VISIBLE CARD (0.0.5): the previous card was a fully transparent view whose
    // height got stretched to the whole reachability area by the outer stack, so
    // it read as "nothing there". Give it a real surface and pin its height to
    // its content (equality, not >=) so the stack cannot stretch it.
    UIView *root = [[UIView alloc] initWithFrame:CGRectZero];
    root.translatesAutoresizingMaskIntoConstraints = NO;
    root.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.42];
    root.layer.cornerRadius = 16;
    root.layer.cornerCurve = kCACornerCurveContinuous;
    root.layer.borderWidth = 1.0 / [UIScreen mainScreen].scale;
    root.layer.borderColor = [[UIColor whiteColor] colorWithAlphaComponent:0.24].CGColor;
    root.clipsToBounds = YES;
    // Highest hugging/compression resistance: never grow to fill spare space.
    [root setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisVertical];
    [root setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisVertical];
    self.view = root;

    self.contentStack = [[UIStackView alloc] init];
    self.contentStack.axis = UILayoutConstraintAxisVertical;
    self.contentStack.spacing = 8;
    self.contentStack.alignment = UIStackViewAlignmentFill;
    self.contentStack.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:self.contentStack];

    [NSLayoutConstraint activateConstraints:@[
        [self.contentStack.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:14],
        [self.contentStack.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-14],
        [self.contentStack.topAnchor constraintEqualToAnchor:root.topAnchor constant:14],
        // Equality: card height follows its content exactly (top 14 + content +
        // bottom 14). A >= here is what let the outer stack stretch it before.
        [root.heightAnchor constraintEqualToAnchor:self.contentStack.heightAnchor constant:28],
        [self.contentStack.heightAnchor constraintGreaterThanOrEqualToConstant:52],
    ]];

    self.emptyLabel = [[UILabel alloc] init];
    self.emptyLabel.text = @"No app is using the camera or microphone";
    self.emptyLabel.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.88];
    self.emptyLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    self.emptyLabel.numberOfLines = 0;
    self.emptyLabel.textAlignment = NSTextAlignmentCenter;
}

- (void)renderRows {
    // Sensor pushes may arrive before the card is ever presented. There is no UI
    // to update yet; -rbView will render from self.rows on first access.
    if (!self.contentStack) return;

    for (UIView *v in [self.contentStack.arrangedSubviews copy]) {
        [self.contentStack removeArrangedSubview:v];
        [v removeFromSuperview];
    }

    if (self.rows.count == 0) {
        [self.contentStack addArrangedSubview:self.emptyLabel];
        return;
    }

    for (NSDictionary *row in self.rows) {
        [self.contentStack addArrangedSubview:[self rowViewFor:row]];
    }
}

- (UIView *)rowViewFor:(NSDictionary *)row {
    UIView *box = [[UIView alloc] init];
    box.translatesAutoresizingMaskIntoConstraints = NO;
    box.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.12];
    box.layer.cornerRadius = 12;
    box.layer.cornerCurve = kCACornerCurveContinuous;

    UIView *dot = [[UIView alloc] init];
    dot.translatesAutoresizingMaskIntoConstraints = NO;
    dot.layer.cornerRadius = 5;
    BOOL isCamera = [row[@"kind"] isEqualToString:@"camera"];
    dot.backgroundColor = isCamera ? [UIColor systemGreenColor] : [UIColor systemOrangeColor];
    [box addSubview:dot];

    UILabel *title = [[UILabel alloc] init];
    title.text = row[@"name"];
    title.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    title.textColor = [row[@"system"] boolValue]
        ? [[UIColor whiteColor] colorWithAlphaComponent:0.6]
        : [UIColor whiteColor];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    [box addSubview:title];

    UILabel *sub = [[UILabel alloc] init];
    sub.text = [NSString stringWithFormat:@"%@ · %@", row[@"kind"], row[@"bundle"]];
    sub.font = [UIFont systemFontOfSize:11 weight:UIFontWeightRegular];
    sub.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.55];
    sub.numberOfLines = 1;
    sub.lineBreakMode = NSLineBreakByTruncatingTail;
    sub.translatesAutoresizingMaskIntoConstraints = NO;
    [box addSubview:sub];

    [NSLayoutConstraint activateConstraints:@[
        [dot.leadingAnchor constraintEqualToAnchor:box.leadingAnchor constant:12],
        [dot.centerYAnchor constraintEqualToAnchor:box.centerYAnchor],
        [dot.widthAnchor constraintEqualToConstant:10],
        [dot.heightAnchor constraintEqualToConstant:10],

        [title.leadingAnchor constraintEqualToAnchor:dot.trailingAnchor constant:10],
        [title.trailingAnchor constraintEqualToAnchor:box.trailingAnchor constant:-12],
        [title.topAnchor constraintEqualToAnchor:box.topAnchor constant:8],

        [sub.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
        [sub.trailingAnchor constraintEqualToAnchor:title.trailingAnchor],
        [sub.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:2],
        [sub.bottomAnchor constraintEqualToAnchor:box.bottomAnchor constant:-8],
        [box.heightAnchor constraintGreaterThanOrEqualToConstant:52],
    ]];
    return box;
}

@end
