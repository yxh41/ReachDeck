#import "RDAppPickerController.h"
#import "RDAppCell.h"

// Settings-side app picker for the launcher card.
//
// Everything runs inside the Settings process, so nothing here reaches into
// SpringBoard: LaunchServices lists the installed apps, and the chosen bundle IDs
// go into the shared plist as "cardCustomApps". The tweak reads that key on every
// rebuild, which is why no respring is involved.
//
// Two rules earned the hard way:
//   * Icons are NEVER decoded on the main thread. A few hundred apps at ~2 ms of
//     PNG decode each is a visible freeze, and a freeze while a controller is
//     being pushed is how picker pages end up crashing.
//   * LSApplicationProxy answers for bundle IDs that are not installed (it
//     returns a lazy placeholder echoing the query), so every candidate is
//     re-checked against the disk first.

static NSUInteger const kRDMaxPickedApps = 4;
static CGFloat const kRDAppIconSide = 29.0;
static NSString *const kRDAppsKey = @"cardCustomApps";

#pragma mark - LaunchServices

@protocol RDAppProxy <NSObject>
- (NSString *)bundleIdentifier;
- (NSString *)localizedName;
- (NSString *)applicationType;
- (NSData *)iconData;
- (NSData *)iconDataForVariant:(int)variant;
- (NSURL *)bundleURL;
- (BOOL)isInstalled;
@end

@protocol RDAppWorkspace <NSObject>
// The +defaultWorkspace hop is on the protocol so the receiver stays typed; on a
// bare id the compiler reports "no known instance method" under -Werror.
+ (id)defaultWorkspace;
- (NSArray *)allApplications;
- (NSArray *)allInstalledApplications;
@end

@interface LSApplicationProxy : NSObject
+ (id<RDAppProxy>)applicationProxyForIdentifier:(NSString *)identifier;
// Declared only so @selector(enumerableApplicationProxies) is not an undeclared
// selector under -Werror; the call itself is still guarded by respondsToSelector.
+ (NSArray *)enumerableApplicationProxies;
@end

static NSCache *RDAppIconCache(void) {
    static NSCache *cache = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache = [[NSCache alloc] init];
        cache.countLimit = 300;
    });
    return cache;
}

static dispatch_queue_t RDAppIconQueue(void) {
    static dispatch_queue_t queue = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("com.zlhkf.reachdeck.appicons", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

static UIImage *RDAppRenderIcon(NSString *bundleID, CGFloat side) {
    if (!bundleID.length) return nil;
    Class cls = NSClassFromString(@"LSApplicationProxy");
    if (!cls) return nil;
    id<RDAppProxy> proxy = (id<RDAppProxy>)[(id)cls applicationProxyForIdentifier:bundleID];
    if (!proxy) return nil;
    NSData *data = nil;
    if ([proxy respondsToSelector:@selector(iconData)]) data = [proxy iconData];
    if (!data.length && [proxy respondsToSelector:@selector(iconDataForVariant:)]) {
        data = [proxy iconDataForVariant:0];
    }
    if (!data.length) return nil;
    UIImage *raw = [UIImage imageWithData:data];
    if (!raw) return nil;
    if (raw.size.width <= side + 1.0 && raw.size.height <= side + 1.0) return raw;

    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.opaque = NO;
    UIGraphicsImageRenderer *renderer =
        [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(side, side) format:fmt];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        (void)ctx;
        [raw drawInRect:CGRectMake(0.0, 0.0, side, side)];
    }];
}

static BOOL RDAppProxyOnDisk(id<RDAppProxy> proxy) {
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

static NSArray *RDAppInstalledList(void) {
    NSMutableArray *result = [NSMutableArray array];

    Class wsCls = NSClassFromString(@"LSApplicationWorkspace");
    if (wsCls) {
        id<RDAppWorkspace> ws = (id<RDAppWorkspace>)[(id)wsCls defaultWorkspace];
        NSArray *list = nil;
        if ([ws respondsToSelector:@selector(allApplications)]) list = [ws allApplications];
        if (!list.count && [ws respondsToSelector:@selector(allInstalledApplications)]) {
            list = [ws allInstalledApplications];
        }
        if (list.count) [result addObjectsFromArray:list];
    }
    if (!result.count) {
        // Fallback for hosts that hide LSApplicationWorkspace: the proxy class
        // itself keeps the enumerable list.
        Class proxyCls = NSClassFromString(@"LSApplicationProxy");
        if (proxyCls && [proxyCls respondsToSelector:@selector(enumerableApplicationProxies)]) {
            NSArray *list = (NSArray *)[(id)proxyCls enumerableApplicationProxies];
            if (list.count) [result addObjectsFromArray:list];
        }
    }
    return result;
}

static NSString *RDAppProxyName(id<RDAppProxy> proxy, NSString *bundleID) {
    if ([proxy respondsToSelector:@selector(localizedName)]) {
        NSString *name = [proxy localizedName];
        if ([name isKindOfClass:[NSString class]] && name.length) return name;
    }
    return bundleID.length ? bundleID : @"App";
}

#pragma mark - controller

@implementation RDAppPickerController

- (instancetype)init {
    self = [super init];
    if (self) {
        self.title = @"选择显示的 App";
    }
    return self;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self rdStartIconLoads];
}

#pragma mark data

- (NSArray<NSString *> *)rdSelectedBundleIDs {
    id list = [[self class] rdSettings][kRDAppsKey];
    if (![list isKindOfClass:[NSArray class]]) return @[];
    NSMutableArray<NSString *> *ids = [NSMutableArray array];
    for (id item in (NSArray *)list) {
        if ([item isKindOfClass:[NSString class]] && [item length]) [ids addObject:item];
    }
    return ids;
}

#pragma mark specifiers

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self rdBuildSpecifiers];
    }
    return _specifiers;
}

- (NSMutableArray *)rdBuildSpecifiers {
    NSMutableArray *out = [NSMutableArray array];
    NSArray<NSString *> *selected = [self rdSelectedBundleIDs];

    PSSpecifier *intro = [PSSpecifier groupSpecifierWithName:@"选择显示的 App"];
    NSString *footer = selected.count
        ? @"点按已选中的 App 可以取消。已选的 App 会取代 Dock，按选择顺序从左到右排列。"
        : @"还没有选择，卡片目前显示 Dock 里的 App。选满 4 个后，卡片只显示你选的这些。";
    [intro setProperty:footer forKey:@"footerText"];
    [out addObject:intro];

    if (selected.count) {
        PSSpecifier *clear = [PSSpecifier preferenceSpecifierNamed:@"清除选择，恢复显示 Dock"
                                                            target:self
                                                               set:NULL
                                                               get:NULL
                                                            detail:nil
                                                              cell:PSButtonCell
                                                              edit:nil];
        [clear setButtonAction:@selector(rdClearSelection)];
        [out addObject:clear];
    }

    PSSpecifier *appsGroup = [PSSpecifier groupSpecifierWithName:@"已安装的 App"];
    [appsGroup setProperty:[NSString stringWithFormat:@"已选 %lu / %lu 个",
                            (unsigned long)selected.count, (unsigned long)kRDMaxPickedApps]
                   forKey:@"footerText"];
    [out addObject:appsGroup];

    NSMutableArray<PSSpecifier *> *rows = [NSMutableArray array];
    for (id obj in RDAppInstalledList()) {
        id<RDAppProxy> proxy = (id<RDAppProxy>)obj;
        if (![proxy respondsToSelector:@selector(bundleIdentifier)]) continue;
        NSString *bid = [proxy bundleIdentifier];
        if (![bid isKindOfClass:[NSString class]] || !bid.length) continue;

        // Only apps the user can actually launch: LaunchServices also lists web
        // apps and internal daemons, which would only add noise.
        if ([proxy respondsToSelector:@selector(applicationType)]) {
            NSString *type = [proxy applicationType];
            if ([type isKindOfClass:[NSString class]] && type.length &&
                ![type isEqualToString:@"User"] && ![type isEqualToString:@"System"]) {
                continue;
            }
        }
        if (!RDAppProxyOnDisk(proxy)) continue;

        PSSpecifier *row = [PSSpecifier preferenceSpecifierNamed:RDAppProxyName(proxy, bid)
                                                          target:self
                                                             set:NULL
                                                             get:NULL
                                                          detail:nil
                                                            cell:PSStaticTextCell
                                                            edit:nil];
        // PSStaticTextCell is only the enum slot; the real row class is ours, the
        // same way the appearance sliders bind RDSliderCell.
        [row setProperty:NSStringFromClass([RDAppCell class]) forKey:@"cellClass"];
        [row setButtonAction:@selector(rdToggleApp:)];
        [row setProperty:bid forKey:@"bid"];
        [row setProperty:@(0) forKey:@"selected"];
        UIImage *icon = [RDAppIconCache() objectForKey:bid];
        if (icon) [row setProperty:icon forKey:@"icon"];
        [rows addObject:row];
    }

    // Sort on the plain name FIRST, then prefix the selection order. Sorting the
    // prefixed labels would order the list by the digit instead of the name.
    [rows sortUsingComparator:^NSComparisonResult(PSSpecifier *a, PSSpecifier *b) {
        NSString *na = [a propertyForKey:@"label"] ?: @"";
        NSString *nb = [b propertyForKey:@"label"] ?: @"";
        return [na localizedStandardCompare:nb];
    }];
    for (PSSpecifier *row in rows) {
        NSString *bid = [row propertyForKey:@"bid"];
        NSUInteger index = [selected indexOfObject:bid];
        if (index == NSNotFound) continue;
        [row setProperty:@YES forKey:@"selected"];
        [row setProperty:[NSString stringWithFormat:@"%lu. %@", (unsigned long)(index + 1),
                          [row propertyForKey:@"label"]]
                  forKey:@"label"];
    }

    if (!rows.count) {
        PSSpecifier *none = [PSSpecifier preferenceSpecifierNamed:@"无法读取已安装的 App 列表"
                                                           target:nil
                                                              set:NULL
                                                              get:NULL
                                                           detail:nil
                                                             cell:PSStaticTextCell
                                                             edit:nil];
        [rows addObject:none];
    }
    [out addObjectsFromArray:rows];
    return out;
}

#pragma mark actions

- (void)rdToggleApp:(PSSpecifier *)specifier {
    NSString *bid = [specifier propertyForKey:@"bid"];
    if (![bid isKindOfClass:[NSString class]] || !bid.length) return;

    NSMutableArray<NSString *> *selected = [[self rdSelectedBundleIDs] mutableCopy];
    if ([selected containsObject:bid]) {
        [selected removeObject:bid];
    } else {
        if (selected.count >= kRDMaxPickedApps) {
            [self rdShowLimitAlert];
            return;
        }
        [selected addObject:bid];
    }
    [[self class] rdSetValue:selected forKey:kRDAppsKey];
    [self rdRebuild];
}

- (void)rdClearSelection {
    // A nil value removes the key entirely, which is what makes the card fall
    // back to the dock instead of showing an empty row.
    [[self class] rdSetValue:nil forKey:kRDAppsKey];
    [self rdRebuild];
}

- (void)rdShowLimitAlert {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"最多选择 4 个"
                         message:@"卡片一行只放得下 4 个图标。想换的话，先取消一个已选的 App。"
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好"
                                             style:UIAlertActionStyleDefault
                                           handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)rdRebuild {
    _specifiers = nil;
    [self reloadSpecifiers];
    [self rdStartIconLoads];
}

#pragma mark icons

- (void)rdStartIconLoads {
    if (!_specifiers.count) return;

    // Snapshot bundle IDs on the main thread: specifier.properties is a mutable
    // dictionary, and reading it from the worker would race the main thread's own
    // writes (a crash, not a cosmetic bug).
    NSMutableArray<NSArray *> *jobs = [NSMutableArray array];
    for (PSSpecifier *spec in _specifiers) {
        NSString *bid = [spec propertyForKey:@"bid"];
        if (![bid isKindOfClass:[NSString class]] || !bid.length) continue;
        if ([RDAppIconCache() objectForKey:bid]) continue;
        [jobs addObject:@[ bid, spec ]];
    }
    if (!jobs.count) return;

    __weak typeof(self) weakSelf = self;
    dispatch_async(RDAppIconQueue(), ^{
        for (NSArray *job in jobs) {
            NSString *bid = job[0];
            PSSpecifier *spec = job[1];
            UIImage *icon = RDAppRenderIcon(bid, kRDAppIconSide);
            if (!icon) continue;
            [RDAppIconCache() setObject:icon forKey:bid];
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(self) strongSelf = weakSelf;
                if (!strongSelf) return;
                [spec setProperty:icon forKey:@"icon"];
                [strongSelf reloadSpecifier:spec animated:NO];
            });
        }
    });
}

@end
