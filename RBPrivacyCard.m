#import "RBPrivacyCard.h"
#import <objc/runtime.h>

// Private but stable SpringBoard-side launcher; guarded by objc_getClass and
// respondsToSelector: before use.
@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (BOOL)openApplicationWithBundleID:(NSString *)bundleID;
@end

static char kRBRowAssociationKey;

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
    [self ingestAttributions:self.lastAttributions activeAttributions:self.lastActiveAttributions];
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

        RBLog(@"attribution OK name=%@ bundle=%@ sensor=%lld system=%d active=%d kind=%@",
              name, bundle, sensor, (int)system, (int)active, kind);

        NSString *key = bundle.length ? bundle : name;
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
    Class cls = objc_getClass("LSApplicationWorkspace");
    if (!cls) { RBLog(@"open app skipped: no LSApplicationWorkspace"); return; }
    LSApplicationWorkspace *ws = (LSApplicationWorkspace *)[cls performSelector:@selector(defaultWorkspace)];
    if (![ws respondsToSelector:@selector(openApplicationWithBundleID:)]) {
        RBLog(@"open app skipped: selector missing");
        return;
    }
    BOOL ok = [ws openApplicationWithBundleID:bundle];
    RBLog(@"open app bundle=%@ ok=%d", bundle, (int)ok);
}

- (void)rbCopyBundle:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) return;
    RBLog(@"row longpress fired");
    NSString *bundle = objc_getAssociatedObject(gesture, &kRBRowAssociationKey);
    if (bundle.length == 0) { RBLog(@"row longpress skipped: no bundle"); return; }
    [UIPasteboard generalPasteboard].string = bundle;
    RBLog(@"copy bundle=%@", bundle);
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
    UIView *root = [[UIView alloc] initWithFrame:CGRectZero];
    root.translatesAutoresizingMaskIntoConstraints = NO;
    root.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.72];
    root.layer.cornerRadius = 16;
    root.layer.cornerCurve = kCACornerCurveContinuous;
    root.layer.borderWidth = 1.0 / [UIScreen mainScreen].scale;
    root.layer.borderColor = [[UIColor whiteColor] colorWithAlphaComponent:0.45].CGColor;
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

    UILabel *header = [[UILabel alloc] init];
    header.text = @"隐私";
    header.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.55];
    header.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
    [self.contentStack addArrangedSubview:header];

    // Rows live in their own stack so renderRows() can clear/repopulate without
    // ever removing the permanent header (a detached arranged subview cannot be
    // re-added, which silently dropped the header in an earlier draft).
    self.rowsStack = [[UIStackView alloc] init];
    self.rowsStack.axis = UILayoutConstraintAxisVertical;
    self.rowsStack.spacing = 8;
    self.rowsStack.alignment = UIStackViewAlignmentFill;
    [self.contentStack addArrangedSubview:self.rowsStack];

    self.emptyLabel = [[UILabel alloc] init];
    self.emptyLabel.text = @"当前没有应用使用相机或麦克风";
    self.emptyLabel.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.92];
    self.emptyLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    self.emptyLabel.numberOfLines = 0;
    self.emptyLabel.textAlignment = NSTextAlignmentLeft;
}

- (void)renderRows {
    // Sensor pushes may arrive before the card is ever presented. There is no UI
    // to update yet; -rbView will render from self.rows on first access.
    if (!self.rowsStack) return;

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
    UIView *box = [[UIView alloc] init];
    box.translatesAutoresizingMaskIntoConstraints = NO;
    box.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.12];
    box.layer.cornerRadius = 12;
    box.layer.cornerCurve = kCACornerCurveContinuous;
    box.tag = 0x52444231; // 'RDB1': the only subview the container hitTest accepts
    box.userInteractionEnabled = YES;

    NSString *rowBundle = row[@"bundle"];
    if (rowBundle.length) {
        UITapGestureRecognizer *tap =
            [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(rbOpenApp:)];
        UILongPressGestureRecognizer *longPress =
            [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(rbCopyBundle:)];
        longPress.minimumPressDuration = 0.5;
        objc_setAssociatedObject(tap, &kRBRowAssociationKey, rowBundle, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(longPress, &kRBRowAssociationKey, rowBundle, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
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
    title.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    title.textColor = [row[@"system"] boolValue]
        ? [[UIColor whiteColor] colorWithAlphaComponent:0.6]
        : [UIColor whiteColor];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    [box addSubview:title];

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
