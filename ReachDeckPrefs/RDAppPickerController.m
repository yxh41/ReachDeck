#import "RDAppPickerController.h"
#import "RDAppCell.h"

// Settings-side app picker for the launcher card.
//
// This screen is plain UIKit. A PSListController version crashed inside
// Preferences.framework while it built cells for a custom cellClass -- the throw
// happens in closed code between "specifier exists" and "cell returned", so
// there is nothing an app-side guard can catch. Owning the table directly
// removes that seam entirely.
//
// Two rules earned the hard way:
//   * Icons are NEVER decoded on the main thread. A few hundred apps at ~2 ms of
//     PNG decode each is a visible freeze while a controller is being pushed.
//   * LSApplicationProxy answers for bundle IDs that are not installed (it
//     returns a lazy placeholder echoing the query), so every candidate is
//     re-checked against the disk first.

static NSUInteger const kRDMaxPickedApps = 10;
static CGFloat const kRDAppIconSide = 32.0;
static NSString *const kRDAppsKey = @"cardCustomApps";
static NSString *const kRDAppRowID = @"RDAppRow";

#define RD_NOTIFY "com.zlhkf.ReachDeck.settings"

// rootful / rootless / roothide: probe the DIRECTORY, not the file. On a fresh
// install the plist does not exist yet; probing the file would fall through to
// /var/jb (not the roothide jbroot) and every write would be silently lost.
// Keep this identical to RDBaseListController.m.
#define RDPlistPath ([[NSFileManager defaultManager] fileExistsAtPath:@"/var/mobile/Library/Preferences"] ? @"/var/mobile/Library/Preferences/com.zlhkf.ReachDeck.plist" : @"/var/jb/var/mobile/Library/Preferences/com.zlhkf.ReachDeck.plist")

#pragma mark - shared settings

static NSMutableDictionary *RDReadSettings(void) {
    NSDictionary *onDisk = [NSDictionary dictionaryWithContentsOfFile:RDPlistPath];
    return onDisk ? [onDisk mutableCopy] : [NSMutableDictionary dictionary];
}

static void RDWriteValueForKey(id value, NSString *key) {
    if (!key.length) return;
    // Read-modify-write a single key. Constructing a fresh dictionary would wipe
    // every switch in the root pane whenever the app list changes.
    NSMutableDictionary *settings = RDReadSettings();
    if (value) {
        [settings setObject:value forKey:key];
    } else {
        [settings removeObjectForKey:key];
    }
    [settings writeToFile:RDPlistPath atomically:YES];

    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         CFSTR(RD_NOTIFY), NULL, NULL, TRUE);
}

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
// Declared only so @selector(enumerableApplicationProxies) is not undeclared
// under -Werror; the call itself is still guarded by respondsToSelector.
+ (NSArray *)enumerableApplicationProxies;
@end

@interface UIImage (RDAppIconLookup)
// The lookup the home screen itself uses. Declared here only so the call is
// type-checked instead of going through performSelector, which drops the return
// type and trips -Werror.
+ (UIImage *)_applicationIconImageForBundleIdentifier:(NSString *)bundleID format:(int)format;
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

// Sampling one pixel is the only honest test: UIKit's private lookup returns a
// correctly sized but fully TRANSPARENT image for some bundles (system apps
// especially), and treating that as "found" leaves an invisible tile.
static BOOL RDImageHasContent(UIImage *image) {
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

// Read the compiled app icon straight out of the .app -- the same approach the
// Oback picker uses. Xcode copies the icon next to Info.plist even when the
// project draws it from an asset catalog, so this covers the bundles whose
// iconData comes back empty.
static UIImage *RDAppIconFromBundle(id<RDAppProxy> proxy) {
    if (![proxy respondsToSelector:@selector(bundleURL)]) return nil;
    NSURL *url = [proxy bundleURL];
    if (![url isKindOfClass:[NSURL class]] || !url.path.length) return nil;

    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:
                          [url.path stringByAppendingPathComponent:@"Info.plist"]];
    if (![info isKindOfClass:[NSDictionary class]]) return nil;

    NSMutableArray<NSString *> *candidates = [NSMutableArray array];
    void (^addName)(id) = ^(id raw) {
        if (![raw isKindOfClass:[NSString class]]) return;
        NSString *name = (NSString *)raw;
        if (!name.length) return;
        [candidates addObject:name];
        [candidates addObject:[NSString stringWithFormat:@"%@@2x", name]];
        [candidates addObject:[NSString stringWithFormat:@"%@@3x", name]];
    };

    addName(info[@"CFBundleIconName"]);
    id icons = info[@"CFBundleIcons"];
    if ([icons isKindOfClass:[NSDictionary class]]) {
        id primary = icons[@"CFBundlePrimaryIcon"];
        if ([primary isKindOfClass:[NSDictionary class]]) {
            addName(primary[@"CFBundleIconName"]);
            id files = primary[@"CFBundleIconFiles"];
            if ([files isKindOfClass:[NSArray class]]) {
                for (id file in files) addName(file);
            }
        }
    }
    id legacy = info[@"CFBundleIconFiles"];
    if ([legacy isKindOfClass:[NSArray class]]) {
        for (id file in legacy) addName(file);
    }

    for (NSString *candidate in candidates) {
        for (NSString *name in @[ candidate, [candidate stringByAppendingString:@".png"] ]) {
            UIImage *img = [UIImage imageWithContentsOfFile:
                            [url.path stringByAppendingPathComponent:name]];
            if (img) return img;
        }
    }
    return nil;
}

static UIImage *RDAppRenderIcon(NSString *bundleID, CGFloat side) {
    if (!bundleID.length) return nil;
    Class cls = NSClassFromString(@"LSApplicationProxy");
    if (!cls) return nil;
    id<RDAppProxy> proxy = (id<RDAppProxy>)[(id)cls applicationProxyForIdentifier:bundleID];
    if (!proxy) return nil;

    // Three lookups, cheapest first. 0.5.3 shipped only #2, and `iconData` comes
    // back empty for most bundles on iOS 16 -- which is why the whole list had
    // no artwork at all.
    UIImage *found = nil;

    // 1. UIKit's private lookup: one XPC round trip and the exact raster the home
    //    screen draws. It hands back a fully TRANSPARENT placeholder for some
    //    bundles, so the pixels are sampled before it is trusted.
    if ([UIImage respondsToSelector:@selector(_applicationIconImageForBundleIdentifier:format:)]) {
        UIImage *img = [UIImage _applicationIconImageForBundleIdentifier:bundleID format:2];
        if (RDImageHasContent(img)) found = img;
    }

    // 2. LaunchServices PNG data.
    if (!found) {
        NSData *data = nil;
        if ([proxy respondsToSelector:@selector(iconData)]) data = [proxy iconData];
        if (!data.length && [proxy respondsToSelector:@selector(iconDataForVariant:)]) {
            data = [proxy iconDataForVariant:0];
        }
        if (data.length) {
            UIImage *img = [UIImage imageWithData:data];
            if (RDImageHasContent(img)) found = img;
        }
    }

    // 3. The bundle's own PNG, the way Oback reads it. Xcode copies the compiled
    //    app icon next to Info.plist, so this works for asset-catalog apps too --
    //    it only costs a file read, which is why it is last.
    if (!found) {
        UIImage *img = RDAppIconFromBundle(proxy);
        if (RDImageHasContent(img)) found = img;
    }

    if (!found) return nil;
    if (found.size.width <= side + 1.0 && found.size.height <= side + 1.0) return found;

    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.opaque = NO;
    UIGraphicsImageRenderer *renderer =
        [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(side, side) format:fmt];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        (void)ctx;
        [found drawInRect:CGRectMake(0.0, 0.0, side, side)];
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

#pragma mark - model

@interface RDAppEntry : NSObject
@property (nonatomic, copy) NSString *bundleID;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, strong) UIImage *icon;
@end

@implementation RDAppEntry
@end

#pragma mark - controller

@interface RDAppPickerController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSMutableArray<RDAppEntry *> *entries;
@property (nonatomic, strong) NSMutableArray<NSString *> *selected;
@end

@implementation RDAppPickerController

- (instancetype)init {
    self = [super init];
    if (self) {
        self.title = @"选择显示的 App";
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];

    UITableView *table = [[UITableView alloc] initWithFrame:self.view.bounds
                                                      style:UITableViewStyleInsetGrouped];
    table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    table.dataSource = self;
    table.delegate = self;
    table.rowHeight = 52.0;
    [table registerClass:[RDAppCell class] forCellReuseIdentifier:kRDAppRowID];
    [self.view addSubview:table];
    self.tableView = table;

    self.selected = [self rdLoadSelected];
    self.entries = [NSMutableArray array];

    [self rdLoadEntries];
    [self rdUpdateClearButton];
    [table reloadData];
    [self rdStartIconLoads];
}

#pragma mark data

- (NSMutableArray<NSString *> *)rdLoadSelected {
    id list = RDReadSettings()[kRDAppsKey];
    NSMutableArray<NSString *> *ids = [NSMutableArray array];
    if (![list isKindOfClass:[NSArray class]]) return ids;
    for (id item in (NSArray *)list) {
        if ([item isKindOfClass:[NSString class]] && [item length]) [ids addObject:item];
    }
    return ids;
}

- (void)rdPersistSelection {
    RDWriteValueForKey([self.selected copy], kRDAppsKey);
}

- (void)rdLoadEntries {
    NSMutableArray<RDAppEntry *> *found = [NSMutableArray array];
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

        RDAppEntry *entry = [[RDAppEntry alloc] init];
        entry.bundleID = bid;
        entry.name = RDAppProxyName(proxy, bid);
        entry.icon = [RDAppIconCache() objectForKey:bid];
        [found addObject:entry];
    }

    [found sortUsingComparator:^NSComparisonResult(RDAppEntry *a, RDAppEntry *b) {
        return [a.name localizedStandardCompare:b.name];
    }];
    [self.entries setArray:found];
}

#pragma mark table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    // A single placeholder row keeps the "nothing found" hint on screen instead
    // of an empty table.
    return self.entries.count ? (NSInteger)self.entries.count : 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (!self.entries.count) return nil;
    return [NSString stringWithFormat:@"已选 %lu / %lu 个",
            (unsigned long)self.selected.count, (unsigned long)kRDMaxPickedApps];
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (!self.entries.count) return @"无法读取已安装的 App 列表，请重开设置再试。";
    if (!self.selected.count) {
        return @"还没有选择，卡片目前显示 Dock 里的 App。最多可以选 10 个：前 5 个排一行，后面的自动换到第二行。";
    }
    return @"点按右侧有蓝色序号的 App 可以取消选择。已选的 App 会取代 Dock，按序号从左到右排列。";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    RDAppCell *cell = [tableView dequeueReusableCellWithIdentifier:kRDAppRowID forIndexPath:indexPath];
    if (!self.entries.count) {
        [cell configureWithName:@"无法读取已安装的 App 列表" icon:nil order:0];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }

    RDAppEntry *entry = self.entries[(NSUInteger)indexPath.row];
    NSUInteger order = [self.selected indexOfObject:entry.bundleID];
    [cell configureWithName:entry.name
                       icon:entry.icon
                      order:(order == NSNotFound ? 0 : order + 1)];
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (!self.entries.count) return;

    NSString *bid = self.entries[(NSUInteger)indexPath.row].bundleID;
    if (!bid.length) return;

    NSUInteger existing = [self.selected indexOfObject:bid];
    if (existing != NSNotFound) {
        [self.selected removeObjectAtIndex:existing];
    } else {
        if (self.selected.count >= kRDMaxPickedApps) {
            [self rdShowLimitAlert];
            return;
        }
        [self.selected addObject:bid];
    }

    [self rdPersistSelection];
    [self rdRefreshSelectionUI];
}

#pragma mark actions

- (void)rdClearSelection {
    // Writing nil removes the key entirely, which is what makes the card fall
    // back to the dock instead of showing an empty row.
    [self.selected removeAllObjects];
    RDWriteValueForKey(nil, kRDAppsKey);
    [self rdRefreshSelectionUI];
}

- (void)rdRefreshSelectionUI {
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:0]
                  withRowAnimation:UITableViewRowAnimationNone];
    [self rdUpdateClearButton];
}

- (void)rdUpdateClearButton {
    if (!self.selected.count) {
        self.navigationItem.rightBarButtonItem = nil;
        return;
    }
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"清除"
                                         style:UIBarButtonItemStylePlain
                                        target:self
                                        action:@selector(rdClearSelection)];
}

- (void)rdShowLimitAlert {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"最多选择 10 个"
                         message:@"卡片排两行：每行 5 个，第二行放剩下的。想换的话，先取消一个已选的 App。"
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好"
                                             style:UIAlertActionStyleDefault
                                           handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark icons

- (void)rdStartIconLoads {
    // Snapshot the entries that still need an icon. The worker only ever reads
    // its own snapshot and hands the bitmap back to the main thread, so no
    // UIKit object is touched off-main except the (thread-safe) drawing itself.
    NSMutableArray<RDAppEntry *> *jobs = [NSMutableArray array];
    for (RDAppEntry *entry in self.entries) {
        if (!entry.icon) [jobs addObject:entry];
    }
    if (!jobs.count) return;

    __weak typeof(self) weakSelf = self;
    dispatch_async(RDAppIconQueue(), ^{
        for (RDAppEntry *entry in jobs) {
            NSString *bid = entry.bundleID;
            UIImage *icon = RDAppRenderIcon(bid, kRDAppIconSide);
            if (!icon) continue;
            [RDAppIconCache() setObject:icon forKey:bid];
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(self) strongSelf = weakSelf;
                if (!strongSelf) return;
                entry.icon = icon;
                NSUInteger row = [strongSelf.entries indexOfObjectIdenticalTo:entry];
                if (row == NSNotFound) return;
                // Guard the row count: the table may have been rebuilt between
                // the snapshot and this callback, and reloading a row that no
                // longer exists is an exception, not a no-op.
                if ([strongSelf.tableView numberOfRowsInSection:0] <= (NSInteger)row) return;
                NSIndexPath *path = [NSIndexPath indexPathForRow:(NSInteger)row inSection:0];
                [strongSelf.tableView reloadRowsAtIndexPaths:@[ path ]
                                            withRowAnimation:UITableViewRowAnimationNone];
            });
        }
    });
}

@end
