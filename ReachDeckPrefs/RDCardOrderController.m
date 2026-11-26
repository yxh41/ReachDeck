#import "RDCardOrderController.h"
#import "RDBaseListController.h"

// Written by rdSetValue:forKey:, which also posts the Darwin notification the
// SpringBoard side listens to, so a reorder is visible on the next (re)mount.
static NSString *const kRDOrderKey = @"cardOrder";

// Must stay in sync with each card's -rbIdentifier in the tweak. The array
// order below is also the built-in rbPriority order used by "restore default".
static NSString *const kRDCardIDs[] = {
    @"dockapps", @"quickcontrols", @"privacy", @"nowplaying", @"clipboard"
};
static NSString *const kRDCardNames[] = {
    @"常用 App", @"快捷开关", @"隐私", @"正在播放", @"剪贴板历史"
};
static NSString *const kRDCardIcons[] = {
    @"app.fill", @"slider.horizontal.3", @"eye.fill", @"music.note", @"doc.on.clipboard.fill"
};
static NSUInteger const kRDCardCount = 5;

@interface RDCardOrderController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSMutableArray<NSString *> *order;
@end

@implementation RDCardOrderController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"卡片顺序";
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"恢复默认"
                                        style:UIBarButtonItemStylePlain
                                       target:self
                                       action:@selector(rdResetOrder)];

    // Load the saved order defensively: drop unknown IDs and duplicates, then
    // append anything missing in built-in order. A stale/partial plist from an
    // upgrade therefore still yields a complete, stable list.
    NSMutableArray<NSString *> *ids = [NSMutableArray arrayWithCapacity:kRDCardCount];
    id stored = [RDBaseListController rdSettings][kRDOrderKey];
    if ([stored isKindOfClass:[NSArray class]]) {
        for (id item in (NSArray *)stored) {
            if (![item isKindOfClass:[NSString class]]) continue;
            if ([self rdIndexForID:item] == NSNotFound) continue;
            if ([ids containsObject:item]) continue;
            [ids addObject:item];
        }
    }
    for (NSUInteger i = 0; i < kRDCardCount; i++) {
        if (![ids containsObject:kRDCardIDs[i]]) [ids addObject:kRDCardIDs[i]];
    }
    self.order = ids;

    UITableView *tv = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    tv.translatesAutoresizingMaskIntoConstraints = NO;
    tv.dataSource = self;
    tv.delegate = self;
    [tv registerClass:[UITableViewCell class] forCellReuseIdentifier:@"rdOrderCell"];
    [self.view addSubview:tv];
    self.tableView = tv;
    [NSLayoutConstraint activateConstraints:@[
        [tv.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [tv.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [tv.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [tv.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
}

- (NSUInteger)rdIndexForID:(NSString *)ident {
    for (NSUInteger i = 0; i < kRDCardCount; i++) {
        if ([kRDCardIDs[i] isEqualToString:ident]) return i;
    }
    return NSNotFound;
}

- (NSString *)rdNameForID:(NSString *)ident {
    NSUInteger i = [self rdIndexForID:ident];
    return (i == NSNotFound) ? ident : kRDCardNames[i];
}

- (UIImage *)rdIconForID:(NSString *)ident {
    NSUInteger i = [self rdIndexForID:ident];
    if (i == NSNotFound) return nil;
    UIImage *img = [UIImage systemImageNamed:kRDCardIcons[i]];
    if (!img) img = [UIImage systemImageNamed:@"square.grid.2x2"];
    return img;
}

- (void)rdSaveOrder {
    // Persist all five IDs, including currently-disabled cards: the tweak
    // simply ignores entries whose card is not enabled, so re-enabling a card
    // later restores its place in the user's order.
    [RDBaseListController rdSetValue:[self.order copy] forKey:kRDOrderKey];
}

- (void)rdResetOrder {
    // Removing the key makes the tweak fall back to rbPriority (upgrade-safe).
    [RDBaseListController rdSetValue:nil forKey:kRDOrderKey];
    NSMutableArray *def = [NSMutableArray arrayWithCapacity:kRDCardCount];
    for (NSUInteger i = 0; i < kRDCardCount; i++) [def addObject:kRDCardIDs[i]];
    self.order = def;
    [self.tableView reloadData];
}

- (void)rdMoveAtIndex:(NSUInteger)index direction:(NSInteger)delta {
    NSInteger target = (NSInteger)index + delta;
    if (target < 0 || target >= (NSInteger)self.order.count) return;
    NSString *moved = self.order[index];
    [self.order removeObjectAtIndex:index];
    [self.order insertObject:moved atIndex:(NSUInteger)target];
    [self rdSaveOrder];
    [self.tableView reloadData];
}

#pragma mark - table

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView; (void)section;
    return (NSInteger)self.order.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"rdOrderCell" forIndexPath:indexPath];
    // Cells are reused across rows; strip the previous row's subviews first.
    for (UIView *v in [cell.contentView.subviews copy]) [v removeFromSuperview];

    NSString *ident = self.order[(NSUInteger)indexPath.row];
    UIImageView *icon = [[UIImageView alloc] initWithImage:[self rdIconForID:ident]];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    icon.tintColor = cell.tintColor;
    icon.contentMode = UIViewContentModeScaleAspectFit;
    [cell.contentView addSubview:icon];

    UILabel *name = [[UILabel alloc] init];
    name.translatesAutoresizingMaskIntoConstraints = NO;
    name.text = [NSString stringWithFormat:@"%lu. %@",
                 (unsigned long)(indexPath.row + 1), [self rdNameForID:ident]];
    [cell.contentView addSubview:name];

    UIButton *up = [UIButton buttonWithType:UIButtonTypeSystem];
    up.translatesAutoresizingMaskIntoConstraints = NO;
    [up setTitle:@"↑" forState:UIControlStateNormal];
    up.titleLabel.font = [UIFont systemFontOfSize:20 weight:UIFontWeightSemibold];
    up.tag = (NSInteger)indexPath.row;
    [up addTarget:self action:@selector(rdMoveUp:) forControlEvents:UIControlEventTouchUpInside];
    [cell.contentView addSubview:up];

    UIButton *down = [UIButton buttonWithType:UIButtonTypeSystem];
    down.translatesAutoresizingMaskIntoConstraints = NO;
    [down setTitle:@"↓" forState:UIControlStateNormal];
    down.titleLabel.font = [UIFont systemFontOfSize:20 weight:UIFontWeightSemibold];
    down.tag = (NSInteger)indexPath.row;
    [down addTarget:self action:@selector(rdMoveDown:) forControlEvents:UIControlEventTouchUpInside];
    [cell.contentView addSubview:down];

    [NSLayoutConstraint activateConstraints:@[
        [icon.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16],
        [icon.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
        [icon.widthAnchor constraintEqualToConstant:24],
        [icon.heightAnchor constraintEqualToConstant:24],
        [name.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor constant:12],
        [name.trailingAnchor constraintLessThanOrEqualToAnchor:up.leadingAnchor constant:-8],
        [name.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
        [down.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-12],
        [down.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
        [down.widthAnchor constraintEqualToConstant:36],
        [down.heightAnchor constraintEqualToConstant:36],
        [up.trailingAnchor constraintEqualToAnchor:down.leadingAnchor constant:0],
        [up.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
        [up.widthAnchor constraintEqualToConstant:36],
        [up.heightAnchor constraintEqualToConstant:36],
    ]];
    return cell;
}

- (void)rdMoveUp:(UIButton *)sender { [self rdMoveAtIndex:(NSUInteger)sender.tag direction:-1]; }
- (void)rdMoveDown:(UIButton *)sender { [self rdMoveAtIndex:(NSUInteger)sender.tag direction:1]; }

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView; (void)section;
    return @"排在最上面的卡片最先显示。改动立即生效；“恢复默认”按内置顺序排列。";
}

@end
