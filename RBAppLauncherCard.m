#import "RBAppLauncherCard.h"
#import "RBPrivacyCard.h"   // RBLog + shared interaction suppression
#import <dlfcn.h>             // dlopen/dlsym for SpringBoardServices

static NSInteger const kRBDockRootTag = 0x52444241; // 'RDBA': card root
static NSInteger const kRBDockTileTag = 0x52444242; // 'RDBB' + index (0..7)
// 0.5.4: up to eight apps, five per row. A sixth app cannot share the first row
// without shrinking every tile below the label's width, so the card grows a
// second row instead of squeezing -- the height follows the constraints, no
// hard-coded "expanded" mode.
static NSUInteger const kRBDockMaxTiles = 8;
static NSUInteger const kRBDockRowTiles = 5;

#pragma mark - private SpringBoard icon model

// Everything below is declared locally so the calls are TYPE-CHECKED instead of
// being funnelled through performSelector (which drops the return type and trips
// -Werror). Every hop is still guarded by respondsToSelector: -- the icon model
// has been re-parented across iOS releases, and a renamed accessor must degrade
// to "this card shows nothing", never to an unrecognised selector inside
// SpringBoard (that is a Safe Mode crash for the sake of four thumbnails).
@protocol RBDockIcon <NSObject>
- (NSString *)applicationBundleIdentifier;
- (NSString *)displayName;
- (id)application;
@end

@protocol RBDockApplication <NSObject>
- (NSString *)bundleIdentifier;
@end

@protocol RBDockModel <NSObject>
- (id)rootFolder;
- (id)dockIconListModel;
@end

@protocol RBDockFolder <NSObject>
- (id)dock;
@end

@protocol RBDockList <NSObject>
- (NSArray *)icons;
@end

@interface SBIconController : NSObject
+ (id)sharedInstance;
- (id)model;
@end

// Icon bitmap lookup. Same two paths the media card uses, and for the same
// reason: UIKit's private lookup is the fast one and returns a correctly sized
// but fully TRANSPARENT placeholder for some bundles (system apps especially),
// so LaunchServices' PNG is kept as the fallback.
@interface UIImage (RBDockIconLookup)
+ (UIImage *)_applicationIconImageForBundleIdentifier:(NSString *)bundleID format:(int)format;
@end

@protocol RBDockProxy <NSObject>
- (NSData *)iconData;
- (NSData *)iconDataForVariant:(int)variant;
- (NSString *)localizedName;
- (NSURL *)bundleURL;
- (BOOL)isInstalled;
@end

@interface LSApplicationProxy : NSObject
+ (id<RBDockProxy>)applicationProxyForIdentifier:(NSString *)identifier;
@end

static BOOL rbDockImageHasContent(UIImage *image) {
    if (!image || !image.CGImage) return NO;
    if (image.size.width < 8.0 || image.size.height < 8.0) return NO;
    unsigned char px[4] = {0, 0, 0, 0};
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(px, 1, 1, 8, 4, space,
                                             (uint32_t)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(space);
    if (!ctx) return YES;   // cannot measure, so trust the lookup
    CGContextSetInterpolationQuality(ctx, kCGInterpolationLow);
    CGContextDrawImage(ctx, CGRectMake(0.0, 0.0, 1.0, 1.0), image.CGImage);
    CGContextRelease(ctx);
    return px[3] > 12;
}

static UIImage *rbDockIconImage(NSString *bundleID, CGFloat side) {
    if (!bundleID.length) return nil;
    UIImage *found = nil;

    if ([UIImage respondsToSelector:@selector(_applicationIconImageForBundleIdentifier:format:)]) {
        UIImage *img = [UIImage _applicationIconImageForBundleIdentifier:bundleID format:2];
        if (rbDockImageHasContent(img)) found = img;
    }
    if (!found) {
        Class cls = NSClassFromString(@"LSApplicationProxy");
        if (cls) {
            id<RBDockProxy> proxy = (id<RBDockProxy>)[(id)cls applicationProxyForIdentifier:bundleID];
            NSData *data = nil;
            if ([proxy respondsToSelector:@selector(iconData)]) data = [proxy iconData];
            if (data.length == 0 && [proxy respondsToSelector:@selector(iconDataForVariant:)]) {
                data = [proxy iconDataForVariant:0];
            }
            if (data.length) {
                UIImage *img = [UIImage imageWithData:data];
                if (rbDockImageHasContent(img)) found = img;
            }
        }
    }
    if (!found) {
        RBLog(@"dock icon none app=%@", bundleID);
        return nil;
    }

    // The private lookup can hand back a 1024px artwork; four of those held only
    // to paint 52pt squares is a pointless few megabytes in SpringBoard.
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.scale = [UIScreen mainScreen].scale;
    fmt.opaque = NO;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(side, side) format:fmt];
    UIImage *scaled = [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        (void)ctx;
        [found drawInRect:CGRectMake(0.0, 0.0, side, side)];
    }];
    return scaled ?: found;
}

// One pass over SpringBoard's icon model for the dock list. Two paths, in the
// order the system itself has kept them working:
//   model -> rootFolder -> dock -> icons      (iOS 13 through 16)
//   model -> dockIconListModel -> icons       (newer list-model plumbing)
static NSArray *rbDockIcons(void) {
    Class cls = NSClassFromString(@"SBIconController");
    if (!cls) { RBLog(@"dock apps: no SBIconController"); return nil; }
    id ctrl = [(id)cls sharedInstance];
    if (!ctrl) { RBLog(@"dock apps: no shared SBIconController"); return nil; }
    id modelObj = [ctrl respondsToSelector:@selector(model)] ? [ctrl model] : nil;
    if (!modelObj) { RBLog(@"dock apps: no icon model"); return nil; }
    id<RBDockModel> model = (id<RBDockModel>)modelObj;

    if ([model respondsToSelector:@selector(rootFolder)]) {
        id<RBDockFolder> folder = (id<RBDockFolder>)[model rootFolder];
        if (folder && [folder respondsToSelector:@selector(dock)]) {
            id<RBDockList> dock = (id<RBDockList>)[folder dock];
            if (dock && [dock respondsToSelector:@selector(icons)]) {
                NSArray *icons = [dock icons];
                RBLog(@"dock apps path=rootFolder count=%lu", (unsigned long)icons.count);
                if (icons.count) return icons;
            }
        }
    }
    if ([model respondsToSelector:@selector(dockIconListModel)]) {
        id<RBDockList> dock = (id<RBDockList>)[model dockIconListModel];
        if (dock && [dock respondsToSelector:@selector(icons)]) {
            NSArray *icons = [dock icons];
            RBLog(@"dock apps path=dockIconListModel count=%lu", (unsigned long)icons.count);
            if (icons.count) return icons;
        }
    }
    RBLog(@"dock apps: no icon list");
    return nil;
}

static NSString *rbDockBundleIDForIcon(id obj) {
    id<RBDockIcon> icon = (id<RBDockIcon>)obj;
    if (!icon) return nil;
    if ([icon respondsToSelector:@selector(applicationBundleIdentifier)]) {
        NSString *bid = [icon applicationBundleIdentifier];
        if ([bid isKindOfClass:[NSString class]] && bid.length) return bid;
    }
    if ([icon respondsToSelector:@selector(application)]) {
        id<RBDockApplication> app = (id<RBDockApplication>)[icon application];
        if (app && [app respondsToSelector:@selector(bundleIdentifier)]) {
            NSString *bid = [app bundleIdentifier];
            if ([bid isKindOfClass:[NSString class]] && bid.length) return bid;
        }
    }
    return nil;
}

static NSString *rbDockNameForIcon(id obj, NSString *fallback) {
    id<RBDockIcon> icon = (id<RBDockIcon>)obj;
    if (icon && [icon respondsToSelector:@selector(displayName)]) {
        NSString *name = [icon displayName];
        if ([name isKindOfClass:[NSString class]] && name.length) return name;
    }
    return fallback.length ? fallback : @"App";
}

// A user-picked list can name an app that has since been deleted, and
// LSApplicationProxy answers for an unknown identifier anyway (it hands back a
// lazy placeholder that echoes the query), so the disk is the only honest test.
static BOOL rbDockAppOnDisk(NSString *bundleID) {
    if (!bundleID.length) return NO;
    Class cls = NSClassFromString(@"LSApplicationProxy");
    if (!cls) return NO;
    id<RBDockProxy> proxy = (id<RBDockProxy>)[(id)cls applicationProxyForIdentifier:bundleID];
    if (!proxy) return NO;
    if ([proxy respondsToSelector:@selector(isInstalled)] && ![proxy isInstalled]) return NO;
    if ([proxy respondsToSelector:@selector(bundleURL)]) {
        NSURL *url = [proxy bundleURL];
        if ([url isKindOfClass:[NSURL class]] && url.path.length) {
            return [[NSFileManager defaultManager] fileExistsAtPath:url.path];
        }
    }
    return YES;
}

static NSString *rbDockDisplayName(NSString *bundleID) {
    Class cls = NSClassFromString(@"LSApplicationProxy");
    if (cls) {
        id<RBDockProxy> proxy = (id<RBDockProxy>)[(id)cls applicationProxyForIdentifier:bundleID];
        if (proxy && [proxy respondsToSelector:@selector(localizedName)]) {
            NSString *name = [proxy localizedName];
            if ([name isKindOfClass:[NSString class]] && name.length) return name;
        }
    }
    return bundleID.lastPathComponent;
}

#pragma mark - launch

// Identical mechanism to the media card, and for the same reason: inside
// SpringBoard -[LSApplicationWorkspace openApplicationWithBundleID:] does not
// return until the target reaches the foreground (a measured 10.1s freeze),
// while SBSLaunchApplicationWithIdentifier only SUBMITS the request. The
// private framework is dlopen'd -- a link-time dependency that failed to
// resolve would take the whole dylib down for one button.
typedef int (*RBDockLaunchFn)(CFStringRef bundleID, Boolean suspended);

static RBDockLaunchFn rbDockLaunchFn(void) {
    static RBDockLaunchFn fn = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *h = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices",
                         RTLD_LAZY);
        if (h) fn = (RBDockLaunchFn)dlsym(h, "SBSLaunchApplicationWithIdentifier");
        RBLog(@"dock launch handle sbs=%d", (int)(fn != NULL));
    });
    return fn;
}

@protocol RBDockWorkspace <NSObject>
+ (id)defaultWorkspace;
- (BOOL)openApplicationWithBundleID:(NSString *)bundleID;
@end

static void rbDockLaunch(NSString *bundleID) {
    if (!bundleID.length) return;
    // Never on the main thread: even the lightweight path is an XPC round trip,
    // and the panel has to stay free to animate away the moment the tile is hit.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        CFTimeInterval t0 = CFAbsoluteTimeGetCurrent();
        RBDockLaunchFn launch = rbDockLaunchFn();
        if (launch) {
            int rc = launch((__bridge CFStringRef)bundleID, false);
            RBLog(@"dock launch via=sbs app=%@ rc=%d took=%.1fms",
                  bundleID, rc, (CFAbsoluteTimeGetCurrent() - t0) * 1000.0);
            if (rc == 0) return;
        }
        Class cls = NSClassFromString(@"LSApplicationWorkspace");
        if (!cls) { RBLog(@"dock launch skipped: no LSApplicationWorkspace"); return; }
        // Two casts: +defaultWorkspace on a Class-typed receiver would be looked
        // up as a class method of an unrelated type under -Werror, and the BOOL
        // return has to survive, so the receiver goes through bare id first.
        id<RBDockWorkspace> ws = (id<RBDockWorkspace>)[(id)cls defaultWorkspace];
        if (!ws) return;
        BOOL ok = [ws openApplicationWithBundleID:bundleID];
        RBLog(@"dock launch via=workspace app=%@ ok=%d took=%.1fms",
              bundleID, (int)ok, (CFAbsoluteTimeGetCurrent() - t0) * 1000.0);
    });
}

#pragma mark - card

@interface RBAppLauncherCard ()
@property (nonatomic, strong) UIView *view;
@property (nonatomic, strong) UILabel *headerLabel;
@property (nonatomic, strong) UIStackView *tilesRow;
@property (nonatomic, strong) UILabel *emptyLabel;
@property (nonatomic, strong) NSArray<UIView *> *tiles;
@property (nonatomic, copy) NSArray<NSString *> *targets;
@property (nonatomic, copy) NSArray<NSString *> *names;
@property (nonatomic, copy) NSArray<NSString *> *customTargets;
@property (nonatomic, assign) CGFloat styleOpacity;
@property (nonatomic, assign) CGFloat styleCorner;
@property (nonatomic, assign) CGFloat styleBorder;
@property (nonatomic, assign) BOOL styleCompact;
- (void)applyTargets;
@end

@implementation RBAppLauncherCard

- (instancetype)init {
    self = [super init];
    if (self) {
        _styleOpacity = 0.20;
        _styleCorner = 16.0;
        _styleBorder = 0.0;
        _styleCompact = NO;
    }
    return self;
}

#pragma mark RBCard

// 50: first in the stack. Opening an app is the one thing this panel is used
// for far more often than anything else it could show.
- (NSInteger)rbPriority { return 50; }
- (NSString *)rbIdentifier { return @"dockapps"; }
- (NSString *)rbRailImageName { return @"app.fill"; }
- (NSString *)rbRailTitle { return @"常用 App"; }

- (UIView *)rbView {
    if (!self.view) {
        [self buildView];
        // The container calls rbRefresh BEFORE asking for the view, so on the
        // first presentation the dock has already been read but there was no
        // view to paint it into. Re-apply now that the tiles exist.
        [self applyTargets];
    }
    return self.view;
}

- (void)rbRefresh {
    // Re-read on every presentation: the dock can change (app installed, removed,
    // rearranged) and nothing tells this card about it.
    [self rbReloadDock];
}

// Called from the container on every rebuild. Clearing the view is what makes the
// change visible: the tiles hold their own labels and icons, so a rebuild is the
// only honest way to apply a different list.
- (void)rbSetCustomTargets:(NSArray<NSString *> *)bundleIDs {
    NSArray<NSString *> *incoming = [bundleIDs isKindOfClass:[NSArray class]] ? bundleIDs : @[];
    NSArray<NSString *> *current = self.customTargets ?: @[];
    if ([incoming isEqualToArray:current]) return;
    self.customTargets = [incoming copy];
    RBLog(@"dock apps custom applied count=%lu", (unsigned long)incoming.count);
    self.view = nil;
    self.headerLabel = nil;
    self.tilesRow = nil;
    self.emptyLabel = nil;
    self.tiles = nil;
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
    RBLog(@"dock style apply opacity=%.2f corner=%.0f border=%.0f compact=%d",
          opacity, corner, border, (int)compact);
    self.view = nil;
    self.headerLabel = nil;
    self.tilesRow = nil;
    self.emptyLabel = nil;
    self.tiles = nil;
}

#pragma mark data

- (void)rbReloadDock {
    // A user-picked list wins. Empty means "follow the dock", which stays the
    // default so an install that was never configured behaves as it always did.
    if (self.customTargets.count) {
        NSMutableArray<NSString *> *cbids = [NSMutableArray array];
        NSMutableArray<NSString *> *cnames = [NSMutableArray array];
        for (NSString *bid in self.customTargets) {
            if (cbids.count >= kRBDockMaxTiles) break;
            if (![bid isKindOfClass:[NSString class]] || !bid.length) continue;
            if ([cbids containsObject:bid]) continue;
            if (!rbDockAppOnDisk(bid)) {
                RBLog(@"dock apps custom skip missing=%@", bid);
                continue;
            }
            [cbids addObject:bid];
            [cnames addObject:rbDockDisplayName(bid)];
        }
        RBLog(@"dock apps custom targets=%lu (%@)",
              (unsigned long)cbids.count, [cbids componentsJoinedByString:@","]);
        self.targets = cbids;
        self.names = cnames;
        [self applyTargets];
        return;
    }
    NSArray *icons = rbDockIcons();
    NSMutableArray<NSString *> *bids = [NSMutableArray array];
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (id icon in icons) {
        if (bids.count >= kRBDockMaxTiles) break;
        NSString *bid = rbDockBundleIDForIcon(icon);
        if (!bid.length) continue;
        // Dedupe: a folder or a stray placeholder in the list must not eat a slot.
        if ([bids containsObject:bid]) continue;
        [bids addObject:bid];
        [names addObject:rbDockNameForIcon(icon, bid.lastPathComponent)];
    }
    RBLog(@"dock apps targets=%lu (%@)",
          (unsigned long)bids.count, [bids componentsJoinedByString:@","]);
    self.targets = bids;
    self.names = names;
    [self applyTargets];
}

- (void)applyTargets {
    if (!self.view) return;
    BOOL has = self.targets.count > 0;
    self.tilesRow.hidden = !has;
    self.emptyLabel.hidden = has;
    if (!has) {
        self.emptyLabel.text = @"读不到 Dock 里的 App";
        return;
    }

    // 0.5.4: smaller tiles so five fit on one row (and eight across two).
    CGFloat side = self.styleCompact ? 38.0 : 44.0;
    for (NSUInteger i = 0; i < self.tiles.count; i++) {
        UIView *tile = self.tiles[i];
        UIImageView *iconView = (UIImageView *)[tile viewWithTag:1001];
        UILabel *nameLabel = (UILabel *)[tile viewWithTag:1002];
        if (i >= self.targets.count) { tile.hidden = YES; continue; }
        tile.hidden = NO;
        NSString *bid = self.targets[i];
        NSString *name = (i < self.names.count) ? self.names[i] : bid;

        UIImage *icon = rbDockIconImage(bid, side);
        if (icon) {
            iconView.image = icon;
            iconView.backgroundColor = [UIColor clearColor];
            iconView.contentMode = UIViewContentModeScaleAspectFit;
        } else {
            // A one-letter chip instead of an invisible hole: the tile has to look
            // like a button even when the artwork cannot be read.
            iconView.image = nil;
            iconView.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.14];
            iconView.contentMode = UIViewContentModeCenter;
        }
        nameLabel.text = name;
        RBLog(@"dock tile idx=%lu app=%@ name=%@ icon=%d",
              (unsigned long)i, bid, name, (int)(icon != nil));
    }
}

#pragma mark actions

- (void)rbTileDown:(UIControl *)sender {
    (void)sender;
    // Arming on touch DOWN, not on touch up: SpringBoard decides whether this
    // touch collapses Reachability long before the finger leaves.
    RBPrivacyArmInteraction();
}

- (void)rbTileUp:(UIControl *)sender {
    NSInteger idx = sender.tag - kRBDockTileTag;
    if (idx < 0 || idx >= (NSInteger)self.targets.count) {
        [self rbScheduleDisarm];
        return;
    }
    NSString *bid = self.targets[(NSUInteger)idx];
    RBLog(@"dock tap idx=%ld app=%@", (long)idx, bid);
    UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [haptic impactOccurred];
    rbDockLaunch(bid);
    // The panel is about to be covered by the launched app anyway; the delayed
    // disarm only matters when the launch is refused.
    [self rbScheduleDisarm];
}

- (void)rbTileCancel:(UIControl *)sender {
    (void)sender;
    [self rbScheduleDisarm];
}

- (void)rbScheduleDisarm {
    // Called only from a completed tap, so a fixed delay is safe here: the touch
    // sequence is already over. (The media card had to learn this the hard way --
    // there a hold outlives the action, here nothing does.)
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        RBPrivacyCancelInteraction();
    });
}

#pragma mark view

- (UIStackView *)rbMakeRow {
    UIStackView *row = [[UIStackView alloc] initWithFrame:CGRectZero];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.distribution = UIStackViewDistributionFillEqually;
    row.alignment = UIStackViewAlignmentCenter;
    row.spacing = self.styleCompact ? 6.0 : 8.0;
    row.translatesAutoresizingMaskIntoConstraints = NO;
    return row;
}

- (UIControl *)rbMakeTileAtIndex:(NSUInteger)index side:(CGFloat)side {
    UIControl *tile = [[UIControl alloc] initWithFrame:CGRectZero];
    tile.tag = kRBDockTileTag + (NSInteger)index;
    tile.userInteractionEnabled = YES;
    tile.translatesAutoresizingMaskIntoConstraints = NO;
    [tile addTarget:self action:@selector(rbTileDown:) forControlEvents:UIControlEventTouchDown];
    [tile addTarget:self action:@selector(rbTileUp:) forControlEvents:UIControlEventTouchUpInside];
    [tile addTarget:self action:@selector(rbTileCancel:) forControlEvents:UIControlEventTouchCancel];
    // 0.5.1: a touch that drags out and back in must still arm, otherwise the
    // second TouchDown of the same sequence arrives with no suppression.
    [tile addTarget:self action:@selector(rbTileDown:) forControlEvents:UIControlEventTouchDragEnter];

    UIImageView *iconView = [[UIImageView alloc] initWithFrame:CGRectZero];
    iconView.tag = 1001;
    iconView.translatesAutoresizingMaskIntoConstraints = NO;
    iconView.userInteractionEnabled = NO;
    iconView.layer.cornerRadius = side * 0.2237;   // the system icon corner ratio
    iconView.layer.cornerCurve = kCACornerCurveContinuous;
    iconView.clipsToBounds = YES;
    iconView.contentMode = UIViewContentModeScaleAspectFit;
    [tile addSubview:iconView];

    UILabel *nameLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    nameLabel.tag = 1002;
    nameLabel.font = [UIFont systemFontOfSize:(self.styleCompact ? 9.0 : 10.0) weight:UIFontWeightRegular];
    nameLabel.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.88];
    nameLabel.textAlignment = NSTextAlignmentCenter;
    nameLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    nameLabel.userInteractionEnabled = NO;
    [tile addSubview:nameLabel];

    // The square is nominal, not absolute: on a narrow card the tile wins, and
    // the icon shrinks with it (height follows width) instead of overflowing.
    NSLayoutConstraint *iconW = [iconView.widthAnchor constraintEqualToConstant:side];
    NSLayoutConstraint *iconH = [iconView.heightAnchor constraintEqualToConstant:side];
    iconW.priority = 999;
    iconH.priority = 999;
    [NSLayoutConstraint activateConstraints:@[
        [iconView.topAnchor constraintEqualToAnchor:tile.topAnchor],
        [iconView.centerXAnchor constraintEqualToAnchor:tile.centerXAnchor],
        iconW, iconH,
        [iconView.widthAnchor constraintLessThanOrEqualToAnchor:tile.widthAnchor],
        [iconView.heightAnchor constraintEqualToAnchor:iconView.widthAnchor],
        [nameLabel.topAnchor constraintEqualToAnchor:iconView.bottomAnchor constant:4.0],
        [nameLabel.leadingAnchor constraintEqualToAnchor:tile.leadingAnchor],
        [nameLabel.trailingAnchor constraintEqualToAnchor:tile.trailingAnchor],
        [nameLabel.bottomAnchor constraintEqualToAnchor:tile.bottomAnchor],
    ]];
    return tile;
}

- (void)buildView {
    CGFloat pad = self.styleCompact ? 8.0 : 11.0;
    CGFloat side = self.styleCompact ? 38.0 : 44.0;
    CGFloat rowGap = self.styleCompact ? 5.0 : 7.0;

    // The row count is decided HERE, from the target list, and never toggled
    // later: a hidden UIStackView keeps every constraint alive, so showing a
    // second row after the fact is the same trap that made the empty state
    // fight Auto Layout before 0.5.1. Building what is needed once is simpler
    // and leaves the card height entirely to the constraint chain.
    NSUInteger shown = MIN(self.targets.count, kRBDockMaxTiles);
    NSUInteger secondRowTiles = (shown > kRBDockRowTiles) ? (shown - kRBDockRowTiles) : 0;

    UIControl *root = [[UIControl alloc] initWithFrame:CGRectZero];
    root.translatesAutoresizingMaskIntoConstraints = NO;
    root.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:self.styleOpacity];
    root.layer.cornerRadius = self.styleCorner;
    root.layer.cornerCurve = kCACornerCurveContinuous;
    root.layer.borderWidth = self.styleBorder;
    root.layer.borderColor = [[UIColor whiteColor] colorWithAlphaComponent:0.75].CGColor;
    root.clipsToBounds = YES;
    root.tag = kRBDockRootTag;
    root.userInteractionEnabled = YES;

    UILabel *header = [[UILabel alloc] initWithFrame:CGRectZero];
    header.text = @"常用 App";
    header.font = [UIFont systemFontOfSize:(self.styleCompact ? 10.0 : 11.0) weight:UIFontWeightSemibold];
    header.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.58];
    header.translatesAutoresizingMaskIntoConstraints = NO;

    NSMutableArray<UIView *> *tiles = [NSMutableArray arrayWithCapacity:kRBDockMaxTiles];

    UIStackView *row1 = [self rbMakeRow];
    for (NSUInteger i = 0; i < kRBDockRowTiles; i++) {
        UIControl *tile = [self rbMakeTileAtIndex:i side:side];
        [row1 addArrangedSubview:tile];
        [tiles addObject:tile];
    }

    UIStackView *row2 = nil;
    if (secondRowTiles > 0) {
        row2 = [self rbMakeRow];
        for (NSUInteger i = 0; i < secondRowTiles; i++) {
            UIControl *tile = [self rbMakeTileAtIndex:(kRBDockRowTiles + i) side:side];
            [row2 addArrangedSubview:tile];
            [tiles addObject:tile];
        }
        // Transparent spacers fill the row out to five slots. FillEqually then
        // hands row 2 the SAME per-tile width as row 1, so a six-app list lines
        // up under a full first row instead of stretching one tile edge to edge.
        for (NSUInteger i = secondRowTiles; i < kRBDockRowTiles; i++) {
            UIView *spacer = [[UIView alloc] initWithFrame:CGRectZero];
            spacer.translatesAutoresizingMaskIntoConstraints = NO;
            spacer.userInteractionEnabled = NO;
            spacer.backgroundColor = [UIColor clearColor];
            [row2 addArrangedSubview:spacer];
        }
    }

    UILabel *empty = [[UILabel alloc] initWithFrame:CGRectZero];
    empty.text = @"读不到 Dock 里的 App";
    empty.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightRegular];
    empty.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.58];
    empty.hidden = YES;
    empty.translatesAutoresizingMaskIntoConstraints = NO;

    [root addSubview:header];
    [root addSubview:row1];
    if (row2) [root addSubview:row2];
    [root addSubview:empty];

    NSMutableArray<NSLayoutConstraint *> *constraints = [NSMutableArray arrayWithArray:@[
        [header.topAnchor constraintEqualToAnchor:root.topAnchor constant:pad],
        [header.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:pad + 1.0],
        [header.trailingAnchor constraintLessThanOrEqualToAnchor:root.trailingAnchor constant:-(pad + 1.0)],

        [row1.topAnchor constraintEqualToAnchor:header.bottomAnchor constant:rowGap],
        [row1.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:pad],
        [row1.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-pad],

        [empty.topAnchor constraintEqualToAnchor:header.bottomAnchor constant:10.0],
        [empty.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:pad + 1.0],
    ]];
    // Only the ROW may define the card's bottom edge. Giving the placeholder its
    // own bottom-to-card equation makes two chains demand different heights for
    // the same view, which Auto Layout resolves by breaking one at random.
    [constraints addObject:[empty.bottomAnchor constraintLessThanOrEqualToAnchor:root.bottomAnchor
                                                                        constant:-(pad + 2.0)]];
    if (row2) {
        [constraints addObjectsFromArray:@[
            [row2.topAnchor constraintEqualToAnchor:row1.bottomAnchor constant:rowGap],
            [row2.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:pad],
            [row2.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-pad],
            [row2.bottomAnchor constraintEqualToAnchor:root.bottomAnchor constant:-pad],
        ]];
    } else {
        [constraints addObject:[row1.bottomAnchor constraintEqualToAnchor:root.bottomAnchor constant:-pad]];
    }
    [NSLayoutConstraint activateConstraints:constraints];

    self.view = root;
    self.headerLabel = header;
    self.tilesRow = row1;
    self.emptyLabel = empty;
    self.tiles = tiles;
}

@end
