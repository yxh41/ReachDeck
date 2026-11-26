#import "RBClipboardCard.h"
#import "RBPrivacyCard.h"   // RBLog + shared interaction suppression
#import <objc/runtime.h>    // associated object: row index

static NSInteger const kRBClipboardTag = 0x52444235; // 'RDB5': clipboard card root
static NSUInteger const kRBHistoryCap = 20;          // in-memory items, newest first
static NSUInteger const kRBDefaultRowLimit = 5;      // visible rows when height unknown

static NSString *RBClipboardSingleLine(NSString *text, NSUInteger limit) {
    if (text.length == 0) return @"";
    NSMutableString *s = [text mutableCopy];
    [s replaceOccurrencesOfString:@"\r" withString:@" " options:0 range:NSMakeRange(0, s.length)];
    [s replaceOccurrencesOfString:@"\n" withString:@" " options:0 range:NSMakeRange(0, s.length)];
    [s replaceOccurrencesOfString:@"\t" withString:@" " options:0 range:NSMakeRange(0, s.length)];
    if (s.length > limit) return [[s substringToIndex:limit] stringByAppendingString:@"…"];
    return s;
}

@interface RBClipboardItem : NSObject
@property (nonatomic, copy) NSString *type;
@property (nonatomic, copy) NSString *detail;
@property (nonatomic, copy) NSString *preview;
@property (nonatomic, copy) NSString *time;
@property (nonatomic, copy) NSString *fingerprint;
@property (nonatomic, strong) id payload;
@end
@implementation RBClipboardItem
@end

@interface RBClipboardCard ()
@property (nonatomic, strong) UIView *view;
@property (nonatomic, strong) UIStackView *contentStack;
@property (nonatomic, strong) UILabel *countLabel;
@property (nonatomic, strong) UILabel *hintLabel;
@property (nonatomic, strong) NSMutableArray<RBClipboardItem *> *history;
@property (nonatomic, strong) NSMutableArray<UIControl *> *rowControls;
@property (nonatomic, assign) NSInteger lastChangeCount;
@property (nonatomic, assign) BOOL historyReady;
@property (nonatomic, assign) BOOL suppressCapture;
@property (nonatomic, assign) CGFloat availableHeight;
@property (nonatomic, assign) CGFloat styleOpacity;
@property (nonatomic, assign) CGFloat styleCorner;
@property (nonatomic, assign) CGFloat styleBorder;
@property (nonatomic, assign) BOOL styleCompact;
@property (nonatomic, strong) dispatch_source_t pollTimer;
- (void)buildView;
- (void)rbStartPolling;
- (void)rbPollPasteboard;
- (BOOL)rbCaptureCurrent;
- (NSUInteger)rbEffectiveRowLimit;
- (void)rbRenderRows;
- (void)rbRestoreAtIndex:(NSUInteger)index;
- (void)rbTouchDown:(UIControl *)sender;
- (void)rbScheduleDisarm;
@end

@implementation RBClipboardCard

- (instancetype)init {
    self = [super init];
    if (self) {
        _styleOpacity = 0.72;
        _styleCorner = 16;
        _styleBorder = 1;
        _styleCompact = NO;
        _history = [NSMutableArray arrayWithCapacity:kRBHistoryCap];
        _rowControls = [NSMutableArray array];
        _lastChangeCount = -1;
        [self rbStartPolling];
    }
    return self;
}

- (void)dealloc {
    if (_pollTimer) {
        dispatch_source_cancel(_pollTimer);
        _pollTimer = nil;
    }
}

#pragma mark - RBCard

- (NSInteger)rbPriority { return 200; }
- (NSString *)rbIdentifier { return @"clipboard"; }
- (BOOL)rbWantsPin { return YES; }
- (NSString *)rbRailImageName { return @"doc.on.clipboard.fill"; }
- (NSString *)rbRailTitle { return @"剪贴板历史"; }

- (UIView *)rbView {
    if (!self.view) {
        [self buildView];
        [self rbCaptureCurrent];
        [self rbRenderRows];
    }
    return self.view;
}

- (void)rbRefresh {
    [self rbCaptureCurrent];
    [self rbRenderRows];
}

- (void)rbWillUnmount {
    // Nothing masked by default; the list is safe to show on every mount.
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
    RBLog(@"clipboard style apply opacity=%.2f corner=%.0f border=%.0f compact=%d",
          opacity, corner, border, (int)compact);
    self.view = nil;
    self.contentStack = nil;
    self.countLabel = nil;
    self.hintLabel = nil;
    [self.rowControls removeAllObjects];
}

- (void)rbSetAvailableHeight:(CGFloat)height {
    if (height <= 0) return;
    if (fabs(height - self.availableHeight) < 1.0) return;
    NSUInteger before = [self rbEffectiveRowLimit];
    self.availableHeight = height;
    NSUInteger after = [self rbEffectiveRowLimit];
    RBLog(@"clipboard available height=%.0f cap %lu->%lu",
          height, (unsigned long)before, (unsigned long)after);
    if (before == after) return;
    [self rbRenderRows];
}

#pragma mark - capture

// 0.6.9: SpringBoard never receives cross-process UIPasteboard notifications,
// so a low-frequency timer polls changeCount. Reading changeCount is a single
// integer read; the clipboard payload is only touched when it actually changed.
- (void)rbStartPolling {
    if (self.pollTimer) return;
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    self.pollTimer = timer;
    dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC, 1 * NSEC_PER_SEC);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(timer, ^{
        __strong typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf rbPollPasteboard];
    });
    dispatch_resume(timer);
    RBLog(@"clipboard history poll started");
}

- (void)rbPollPasteboard {
    BOOL added = [self rbCaptureCurrent];
    if (added) [self rbRenderRows];
}

- (BOOL)rbCaptureCurrent {
    UIPasteboard *pb = [UIPasteboard generalPasteboard];
    NSInteger cc = pb.changeCount;
    if (self.historyReady && cc == self.lastChangeCount) return NO;
    self.historyReady = YES;
    self.lastChangeCount = cc;
    if (self.suppressCapture) {
        self.suppressCapture = NO;
        return NO;
    }

    NSString *type = nil, *detail = nil, *preview = nil, *fingerprint = nil;
    id payload = nil;

    if (pb.hasStrings) {
        NSString *text = pb.string;
        if (text.length > 0) {
            type = @"文本";
            detail = [NSString stringWithFormat:@"%lu 字", (unsigned long)text.length];
            preview = RBClipboardSingleLine(text, 60);
            fingerprint = [@"t:" stringByAppendingString:text];
            payload = [text copy];
        }
    } else if (pb.hasImages) {
        UIImage *image = pb.image;
        if (image) {
            type = @"图片";
            CGFloat w = image.size.width * image.scale;
            CGFloat h = image.size.height * image.scale;
            detail = [NSString stringWithFormat:@"%.0f × %.0f", w, h];
            preview = @"图片内容";
            // An image has no cheap stable hash; size + pixel count is enough
            // to collapse consecutive duplicates of the same screenshot.
            fingerprint = [NSString stringWithFormat:@"i:%.0fx%.0f:%lu",
                           w, h, (unsigned long)(w * h)];
            payload = image;
        }
    } else if (pb.hasURLs) {
        NSURL *url = pb.URL;
        if (url.absoluteString.length > 0) {
            type = @"链接";
            detail = [NSString stringWithFormat:@"%lu 字符", (unsigned long)url.absoluteString.length];
            preview = RBClipboardSingleLine(url.absoluteString, 60);
            fingerprint = [@"u:" stringByAppendingString:url.absoluteString];
            payload = url;
        }
    }
    if (!type || !fingerprint) {
        RBLog(@"clipboard history clear-or-empty cc=%ld", (long)cc);
        return NO;
    }

    static NSDateFormatter *fmt = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        fmt = [[NSDateFormatter alloc] init];
        fmt.dateFormat = @"HH:mm:ss";
    });

    // Same content copied again: bump its timestamp and move to the front,
    // but do not grow the list.
    if (self.history.count > 0) {
        RBClipboardItem *head = self.history[0];
        if ([head.fingerprint isEqualToString:fingerprint]) {
            head.time = [fmt stringFromDate:[NSDate date]];
            RBLog(@"clipboard history dup type=%@ count=%lu cc=%ld",
                  type, (unsigned long)self.history.count, (long)cc);
            return NO;
        }
    }

    RBClipboardItem *item = [[RBClipboardItem alloc] init];
    item.type = type;
    item.detail = detail;
    item.preview = preview;
    item.time = [fmt stringFromDate:[NSDate date]];
    item.fingerprint = fingerprint;
    item.payload = payload;
    [self.history insertObject:item atIndex:0];
    while (self.history.count > kRBHistoryCap) [self.history removeLastObject];

    RBLog(@"clipboard history add type=%@ count=%lu cc=%ld",
          type, (unsigned long)self.history.count, (long)cc);
    return YES;
}

#pragma mark - rows

// height(N) = pad*2 + headerH + gap + N*rowH + (N-1)*gap.
- (NSUInteger)rbEffectiveRowLimit {
    NSUInteger total = self.history.count;
    if (total == 0) return 0;
    if (self.availableHeight <= 0) return MIN(total, kRBDefaultRowLimit);
    CGFloat pad = _styleCompact ? 9.0 : 12.0;
    CGFloat gap = _styleCompact ? 5.0 : 7.0;
    CGFloat rowH = _styleCompact ? 40.0 : 46.0;
    CGFloat headerH = _styleCompact ? 13.0 : 14.0;
    CGFloat fixed = pad * 2 + headerH + gap;
    CGFloat room = self.availableHeight - fixed;
    if (room <= 0) return 1;
    NSUInteger cap = (NSUInteger)floor((room + gap) / (rowH + gap));
    if (cap < 1) cap = 1;
    if (cap > kRBDefaultRowLimit) cap = kRBDefaultRowLimit;
    return MIN(total, cap);
}

- (void)rbRenderRows {
    if (!self.contentStack) return;
    for (UIControl *c in self.rowControls) {
        [c removeFromSuperview];
    }
    [self.rowControls removeAllObjects];

    if (self.history.count == 0) {
        if (!self.hintLabel) {
            self.hintLabel = [[UILabel alloc] init];
            self.hintLabel.numberOfLines = 1;
            self.hintLabel.lineBreakMode = NSLineBreakByTruncatingTail;
            self.hintLabel.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.52];
            self.hintLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightRegular];
            self.hintLabel.userInteractionEnabled = NO;
        }
        self.hintLabel.text = @"复制内容后会显示在这里，点按任一历史即可回填";
        [self.contentStack addArrangedSubview:self.hintLabel];
    } else {
        if (self.hintLabel.superview == self.contentStack) {
            [self.hintLabel removeFromSuperview];
        }
        NSUInteger limit = [self rbEffectiveRowLimit];
        for (NSUInteger i = 0; i < limit; i++) {
            RBClipboardItem *item = self.history[i];
            UIControl *row = [self rbRowForItem:item index:i];
            [self.contentStack addArrangedSubview:row];
            [self.rowControls addObject:row];
        }
    }
    self.countLabel.text = self.history.count
        ? [NSString stringWithFormat:@"%lu 条", (unsigned long)self.history.count]
        : @"";
}

// Each row deliberately reuses 'RDB5' so the container's hitTest whitelist and
// 0.6.7's card-region touch arming cover it with no change to Tweak.xm.
- (UIControl *)rbRowForItem:(RBClipboardItem *)item index:(NSUInteger)index {
    UIControl *row = [[UIControl alloc] init];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    row.tag = kRBClipboardTag;
    row.userInteractionEnabled = YES;
    row.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.06];
    row.layer.cornerRadius = 7;
    row.layer.cornerCurve = kCACornerCurveContinuous;
    [row addTarget:self action:@selector(rbTouchDown:) forControlEvents:UIControlEventTouchDown];
    [row addTarget:self action:@selector(rbRowTapped:)
          forControlEvents:UIControlEventTouchUpInside];
    [row addTarget:self action:@selector(rbScheduleDisarm)
          forControlEvents:(UIControlEventTouchCancel | UIControlEventTouchUpOutside)];

    UILabel *typeL = [[UILabel alloc] init];
    typeL.text = item.type;
    typeL.font = [UIFont systemFontOfSize:(_styleCompact ? 10 : 11) weight:UIFontWeightSemibold];
    typeL.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.66];
    typeL.textAlignment = NSTextAlignmentCenter;
    [typeL setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [typeL setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];

    UILabel *previewL = [[UILabel alloc] init];
    previewL.text = item.preview;
    previewL.numberOfLines = 1;
    previewL.lineBreakMode = NSLineBreakByTruncatingTail;
    previewL.font = [UIFont systemFontOfSize:(_styleCompact ? 12 : 13) weight:UIFontWeightRegular];
    previewL.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.94];

    UILabel *timeL = [[UILabel alloc] init];
    timeL.text = item.time ?: @"";
    timeL.font = [UIFont systemFontOfSize:10 weight:UIFontWeightRegular];
    timeL.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.50];
    [timeL setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];

    UIStackView *line = [[UIStackView alloc] initWithArrangedSubviews:@[typeL, previewL, timeL]];
    line.axis = UILayoutConstraintAxisHorizontal;
    line.alignment = UIStackViewAlignmentCenter;
    line.spacing = 8;
    line.translatesAutoresizingMaskIntoConstraints = NO;
    line.userInteractionEnabled = NO;
    [row addSubview:line];

    CGFloat inset = _styleCompact ? 8.0 : 10.0;
    [NSLayoutConstraint activateConstraints:@[
        [line.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:inset],
        [line.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-inset],
        [line.topAnchor constraintEqualToAnchor:row.topAnchor constant:4],
        [line.bottomAnchor constraintEqualToAnchor:row.bottomAnchor constant:-4],
        [typeL.widthAnchor constraintEqualToConstant:(_styleCompact ? 30 : 34)],
    ]];
    [row setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisVertical];
    [row setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisVertical];
    objc_setAssociatedObject(row, "rbIndex", @(index), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return row;
}

#pragma mark - restore

- (void)rbRestoreAtIndex:(NSUInteger)index {
    if (index >= self.history.count) return;
    RBClipboardItem *item = self.history[index];
    UIPasteboard *pb = [UIPasteboard generalPasteboard];
    if ([item.payload isKindOfClass:[NSString class]]) {
        pb.string = (NSString *)item.payload;
    } else if ([item.payload isKindOfClass:[UIImage class]]) {
        pb.image = (UIImage *)item.payload;
    } else if ([item.payload isKindOfClass:[NSURL class]]) {
        pb.URL = (NSURL *)item.payload;
    }
    self.suppressCapture = YES;
    self.lastChangeCount = pb.changeCount;
    RBLog(@"clipboard history restore type=%@ index=%lu",
          item.type, (unsigned long)index);
    [self rbScheduleDisarm];
}

- (void)rbRowTapped:(UIControl *)sender {
    NSNumber *n = objc_getAssociatedObject(sender, "rbIndex");
    if (n) [self rbRestoreAtIndex:n.unsignedIntegerValue];
}

#pragma mark - interaction

- (void)rbTouchDown:(UIControl *)sender {
    (void)sender;
    RBPrivacyArmInteraction();
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

- (void)buildView {
    CGFloat pad = _styleCompact ? 9 : 12;
    CGFloat gap = _styleCompact ? 5 : 7;

    UIView *root = [[UIView alloc] initWithFrame:CGRectZero];
    root.translatesAutoresizingMaskIntoConstraints = NO;
    root.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:_styleOpacity];
    root.layer.cornerRadius = _styleCorner;
    root.layer.cornerCurve = kCACornerCurveContinuous;
    root.layer.borderWidth = _styleBorder;
    root.layer.borderColor = [[UIColor whiteColor] colorWithAlphaComponent:0.75].CGColor;
    root.clipsToBounds = YES;
    root.tag = kRBClipboardTag;
    root.userInteractionEnabled = YES;
    [root setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisVertical];
    [root setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisVertical];
    self.view = root;

    self.contentStack = [[UIStackView alloc] init];
    self.contentStack.axis = UILayoutConstraintAxisVertical;
    self.contentStack.spacing = gap;
    self.contentStack.alignment = UIStackViewAlignmentFill;
    self.contentStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.contentStack.userInteractionEnabled = YES;
    [root addSubview:self.contentStack];

    [NSLayoutConstraint activateConstraints:@[
        [self.contentStack.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:pad],
        [self.contentStack.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-pad],
        [self.contentStack.topAnchor constraintEqualToAnchor:root.topAnchor constant:pad],
        [root.heightAnchor constraintEqualToAnchor:self.contentStack.heightAnchor constant:pad * 2],
        [self.contentStack.heightAnchor constraintGreaterThanOrEqualToConstant:36],
    ]];

    UIStackView *headerRow = [[UIStackView alloc] init];
    headerRow.axis = UILayoutConstraintAxisHorizontal;
    headerRow.alignment = UIStackViewAlignmentCenter;
    headerRow.spacing = 8;
    headerRow.userInteractionEnabled = NO;

    UILabel *header = [[UILabel alloc] init];
    header.text = @"剪贴板历史";
    header.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.55];
    header.font = [UIFont systemFontOfSize:(_styleCompact ? 10 : 11) weight:UIFontWeightSemibold];
    [header setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [headerRow addArrangedSubview:header];

    self.countLabel = [[UILabel alloc] init];
    self.countLabel.textAlignment = NSTextAlignmentRight;
    self.countLabel.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.62];
    self.countLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightRegular];
    [self.countLabel setContentCompressionResistancePriority:UILayoutPriorityDefaultLow
                                                     forAxis:UILayoutConstraintAxisHorizontal];
    [headerRow addArrangedSubview:self.countLabel];
    [self.contentStack addArrangedSubview:headerRow];
}

@end
