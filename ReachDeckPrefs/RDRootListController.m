#import "RDRootListController.h"
#import "RDAppPickerController.h"

@implementation RDRootListController

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
        // The picker row is a PSButtonCell: Preferences only routes a tap to us
        // when the specifier carries an action, so it is bound here rather than
        // in the plist (an action selector in XML cannot name our class).
        for (PSSpecifier *spec in _specifiers) {
            if ([[spec propertyForKey:@"id"] isEqualToString:@"rdAppPickerLink"]) {
                [spec setButtonAction:@selector(rdOpenAppPicker)];
                self.rdPickerLink = spec;
            }
        }
    }
    return _specifiers;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self rdUpdatePickerLinkTitle];
}

- (void)rdOpenAppPicker {
    RDAppPickerController *picker = [[RDAppPickerController alloc] init];
    [self.navigationController pushViewController:picker animated:YES];
}

- (void)rdUpdatePickerLinkTitle {
    if (!self.rdPickerLink) return;
    id list = [[self class] rdSettings][@"cardCustomApps"];
    NSUInteger count = [list isKindOfClass:[NSArray class]] ? [(NSArray *)list count] : 0;
    NSString *title = count
        ? [NSString stringWithFormat:@"选择显示的 App（已选 %lu 个）", (unsigned long)count]
        : @"选择显示的 App（跟随 Dock）";
    [self.rdPickerLink setProperty:title forKey:@"label"];
    [self reloadSpecifier:self.rdPickerLink animated:NO];
}

@end
