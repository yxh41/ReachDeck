#import "RBClipboardCard.h"
#import "RBPrivacyCard.h"   // RBLog + shared interaction suppression

static NSInteger const kRBClipboardTag = 0x52444235; // 'RDB5': clipboard card root

static NSString *RBClipboardSingleLine(NSString *text, NSUInteger limit) {
    if (text.length == 0) return @"";
    NSMutableString *s = [text mutableCopy];
    [s replaceOccurrencesOfString:@"\r" withString:@" " options:0 range:NSMakeRange(0, s.length)];
    [s replaceOccurrencesOfString:@"\n" withString:@" " options:0 range:NSMakeRange(0, s.length)];
    [s replaceOccurrencesOfString:@"\t" withString:@" " options:0 range:NSMakeRange(0, s.length)];
    if (s.length > limit) return [[s substringToIndex:limit] stringByAppendingString:@"…"];
    return s;
}

@interface RBClipboardCard ()
@property (nonatomic, strong) UIView *view;
@property (nonatomic, strong) UIStackView *contentStack;
@property (nonatomic, strong) UILabel *headerLabel;
@property (nonatomic, strong) UILabel *typeLabel;
@property (nonatomic, strong) UILabel *previewLabel;
@property (nonatomic, strong) UILabel *hintLabel;
@property (nonatomic, copy) NSString *clipType;
@property (nonatomic, copy) NSString *clipDetail;
@property (nonatomic, copy) NSString *clipPreview;
@property (nonatomic, assign) BOOL hasContent;
@property (nonatomic, assign) BOOL revealed;
@property (nonatomic, assign) CGFloat styleOpacity;
@property (nonatomic, assign) CGFloat styleCorner;
@property (nonatomic, assign) CGFloat styleBorder;
@property (nonatomic, assign) BOOL styleCompact;
- (void)buildView;
- (void)rbReadPasteboard;
- (void)rbUpdateLabels;
- (void)rbPasteboardChanged:(NSNotification *)note;
- (void)rbTouchDown:(UIControl *)sender;
- (void)rbTouchUp:(UIControl *)sender;
- (void)rbTouchCancel:(UIControl *)sender;
- (void)rbScheduleDisarm;
@end

@implementation RBClipboardCard

- (instancetype)init {
    self = [super init];
    if (self) {
        // These defaults match RBPrivacyCard so the two cards look like one deck.
        _styleOpacity = 0.72;
        _styleCorner = 16;
        _styleBorder = 1;
        _styleCompact = NO;
        _revealed = NO;
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(rbPasteboardChanged:)
                                                     name:UIPasteboardChangedNotification
                                                   object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - RBCard

- (NSInteger)rbPriority { return 200; }
- (NSString *)rbIdentifier { return @"clipboard"; }
- (BOOL)rbWantsPin { return YES; }
- (NSString *)rbRailImageName { return @"doc.on.clipboard.fill"; }
- (NSString *)rbRailTitle { return @"剪贴板"; }

- (UIView *)rbView {
    if (!self.view) {
        [self buildView];
        [self rbReadPasteboard];
        [self rbUpdateLabels];
    }
    return self.view;
}

- (void)rbRefresh {
    [self rbReadPasteboard];
    [self rbUpdateLabels];
}

- (void)rbWillUnmount {
    // Clipboard content stays masked on every new Reachability presentation.
    self.revealed = NO;
    [self rbUpdateLabels];
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
    self.headerLabel = nil;
    self.typeLabel = nil;
    self.previewLabel = nil;
    self.hintLabel = nil;
}

#pragma mark - pasteboard

- (void)rbPasteboardChanged:(NSNotification *)note {
    (void)note;
    // Weak self: the card is a long-lived singleton, so a self-retaining block
    // would keep a stale UI alive after a style rebuild.
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        __strong typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf rbRefresh];
    });
}

- (void)rbReadPasteboard {
    UIPasteboard *pb = [UIPasteboard generalPasteboard];
    NSString *type = nil;
    NSString *detail = nil;
    NSString *preview = nil;
    NSUInteger length = 0;

    if (pb.hasStrings) {
        NSString *text = pb.string;
        if (text.length > 0) {
            type = @"文本";
            length = text.length;
            detail = [NSString stringWithFormat:@"%lu 字", (unsigned long)length];
            preview = RBClipboardSingleLine(text, 96);
        }
    } else if (pb.hasImages) {
        UIImage *image = pb.image;
        if (image) {
            type = @"图片";
            CGFloat w = image.size.width * image.scale;
            CGFloat h = image.size.height * image.scale;
            detail = [NSString stringWithFormat:@"%.0f × %.0f", w, h];
            preview = @"图片内容";
            length = (NSUInteger)(w * h);
        }
    } else if (pb.hasURLs) {
        NSURL *url = pb.URL;
        if (url.absoluteString.length > 0) {
            type = @"链接";
            length = url.absoluteString.length;
            detail = [NSString stringWithFormat:@"%lu 字符", (unsigned long)length];
            preview = RBClipboardSingleLine(url.absoluteString, 96);
        }
    }

    BOOL has = type.length > 0;
    NSString *typeCmp = type ?: @"";
    NSString *detailCmp = detail ?: @"";
    NSString *previewCmp = preview ?: @"";
    BOOL changed = (has != self.hasContent) ||
                   ![typeCmp isEqualToString:self.clipType ?: @""] ||
                   ![detailCmp isEqualToString:self.clipDetail ?: @""] ||
                   ![previewCmp isEqualToString:self.clipPreview ?: @""];
    self.hasContent = has;
    self.clipType = has ? type : nil;
    self.clipDetail = has ? detail : nil;
    self.clipPreview = has ? preview : nil;
    if (changed) self.revealed = NO;
    RBLog(@"clipboard type=%@ chars=%lu revealed=%d",
          has ? type : @"none", (unsigned long)length, (int)self.revealed);
}

- (void)rbUpdateLabels {
    if (!self.view) return;
    self.headerLabel.text = @"剪贴板";
    self.typeLabel.text = self.hasContent ? self.clipType : @"";
    if (!self.hasContent) {
        self.previewLabel.text = @"剪贴板为空";
        self.previewLabel.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.58];
        self.hintLabel.text = @"复制内容后会显示在这里";
        return;
    }
    self.previewLabel.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.94];
    self.previewLabel.text = self.revealed ? self.clipPreview : @"••••••";
    self.hintLabel.text = [NSString stringWithFormat:@"%@ · %@ · %@",
                           self.clipType, self.clipDetail,
                           self.revealed ? @"点按隐藏" : @"点按显示"];
}

#pragma mark - view

- (void)buildView {
    CGFloat pad = _styleCompact ? 9 : 12;
    CGFloat gap = _styleCompact ? 4 : 6;

    UIControl *root = [[UIControl alloc] initWithFrame:CGRectZero];
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
    [root addTarget:self action:@selector(rbTouchDown:)
   forControlEvents:UIControlEventTouchDown];
    [root addTarget:self action:@selector(rbTouchUp:)
   forControlEvents:UIControlEventTouchUpInside];
    [root addTarget:self action:@selector(rbTouchCancel:)
   forControlEvents:(UIControlEventTouchCancel |
                     UIControlEventTouchUpOutside |
                     UIControlEventTouchDragExit)];
    self.view = root;

    self.contentStack = [[UIStackView alloc] init];
    self.contentStack.axis = UILayoutConstraintAxisVertical;
    self.contentStack.spacing = gap;
    self.contentStack.alignment = UIStackViewAlignmentFill;
    self.contentStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.contentStack.userInteractionEnabled = NO; // whole card is one button
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

    self.headerLabel = [[UILabel alloc] init];
    self.headerLabel.text = @"剪贴板";
    self.headerLabel.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.55];
    self.headerLabel.font = [UIFont systemFontOfSize:(_styleCompact ? 10 : 11) weight:UIFontWeightSemibold];
    self.headerLabel.userInteractionEnabled = NO;
    [self.headerLabel setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [headerRow addArrangedSubview:self.headerLabel];

    self.typeLabel = [[UILabel alloc] init];
    self.typeLabel.textAlignment = NSTextAlignmentRight;
    self.typeLabel.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.68];
    self.typeLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightRegular];
    self.typeLabel.userInteractionEnabled = NO;
    [self.typeLabel setContentCompressionResistancePriority:UILayoutPriorityDefaultLow
                                                   forAxis:UILayoutConstraintAxisHorizontal];
    [headerRow addArrangedSubview:self.typeLabel];
    [self.contentStack addArrangedSubview:headerRow];

    self.previewLabel = [[UILabel alloc] init];
    self.previewLabel.numberOfLines = 2;
    self.previewLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    self.previewLabel.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.94];
    self.previewLabel.font = [UIFont systemFontOfSize:(_styleCompact ? 13 : 14) weight:UIFontWeightSemibold];
    self.previewLabel.userInteractionEnabled = NO;
    [self.contentStack addArrangedSubview:self.previewLabel];

    self.hintLabel = [[UILabel alloc] init];
    self.hintLabel.numberOfLines = 1;
    self.hintLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    self.hintLabel.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.52];
    self.hintLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightRegular];
    self.hintLabel.userInteractionEnabled = NO;
    [self.contentStack addArrangedSubview:self.hintLabel];
}

#pragma mark - interaction

// Same rule as the privacy card footer: arm suppression on touchDown, because
// SpringBoard's dismiss callback can arrive before touchUpInside.
- (void)rbTouchDown:(UIControl *)sender {
    (void)sender;
    RBPrivacyArmInteraction();
    RBLog(@"clipboard touch down");
}

- (void)rbTouchUp:(UIControl *)sender {
    (void)sender;
    if (self.hasContent) {
        self.revealed = !self.revealed;
        [self rbUpdateLabels];
        RBLog(@"clipboard reveal=%d", (int)self.revealed);
    }
    [self rbScheduleDisarm];
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

@end
