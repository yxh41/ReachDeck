#import "RDBaseListController.h"
#import <objc/runtime.h>
#import <stdarg.h>

#define RD_NOTIFY "com.zlhkf.ReachDeck.settings"

// rootful / rootless / roothide: probe the DIRECTORY, not the file. On a fresh
// install the plist does not exist yet; probing the file would fall through to
// /var/jb (not the roothide jbroot, so it does not exist) and every write would
// be silently lost. Keep the two files byte-for-byte identical in logic.
#define RDPlistPath ([[NSFileManager defaultManager] fileExistsAtPath:@"/var/mobile/Library/Preferences"] ? @"/var/mobile/Library/Preferences/com.zlhkf.ReachDeck.plist" : @"/var/jb/var/mobile/Library/Preferences/com.zlhkf.ReachDeck.plist")

// Preferences is a separate process from SpringBoard. Write into the SAME
// debug.log the tweak uses so the user can grab one file and see both sides.
// Prefix every line with [Prefs] to tell them apart.
static void RDPrefsLog(NSString * _Nonnull fmt, ...) {
    va_list args; va_start(args, fmt);
    NSString *body = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSString *path = [[NSFileManager defaultManager] fileExistsAtPath:@"/var/mobile/Library/Preferences"]
        ? @"/var/mobile/Library/Preferences/com.zlhkf.ReachDeck.debug.log"
        : @"/var/jb/var/mobile/Library/Preferences/com.zlhkf.ReachDeck.debug.log";
    NSString *line = [NSString stringWithFormat:@"[Prefs] %@\n", body];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (fh) {
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    } else {
        [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
}

static char kRDValueLabelKey;
static char kRDSliderHookedKey;

@implementation RDBaseListController

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSDictionary *settings = [NSDictionary dictionaryWithContentsOfFile:RDPlistPath];
    id value = settings[specifier.properties[@"key"]];
    return value ?: specifier.properties[@"default"];
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    // Read-modify-write a single key. Constructing a fresh dict here would wipe the
    // other switches whenever one is toggled.
    NSMutableDictionary *settings = [NSMutableDictionary dictionary];
    [settings addEntriesFromDictionary:[NSDictionary dictionaryWithContentsOfFile:RDPlistPath]];
    [settings setObject:value forKey:specifier.properties[@"key"]];
    [settings writeToFile:RDPlistPath atomically:YES];

    [super setPreferenceValue:value specifier:specifier];

    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        CFSTR(RD_NOTIFY), NULL, NULL, TRUE);
}

#pragma mark - slider value label

// Native PSSliderCell renders showValue with "%.1f" and pins the value label to
// the grouped cell's right edge, where the rounded corner clips the last digit.
// Prior attempts nudged that label with a transform (-9pt, then a computed
// shift), but at cellForRow time the cell is not laid out yet and the native
// label can be re-laid-out/reused later, so the nudge was lost or wrong on
// device. We cannot subclass PSSliderCell either: the roothide SDK neither ships
// its header nor exports _OBJC_CLASS_$_PSSliderCell for linking.
//
// Final approach: hide the native value label and install OUR OWN label pinned
// by Auto Layout to contentView.trailing - 16 (well clear of the corner). The
// integer text is taken straight from slider.value on every change. Auto Layout
// constraints survive cell reuse and re-layout, so this is stable.

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    // PSListController (a UITableViewController data source) always implements
    // cellForRowAtIndexPath, so calling super is safe. willDisplayCell: is an
    // OPTIONAL delegate method the superclass chain may not implement.
    UITableViewCell *cell = [super tableView:tableView cellForRowAtIndexPath:indexPath];
    [self rd_setupValueLabelInCell:cell];
    return cell;
}

- (UISlider *)rd_sliderInCell:(UITableViewCell *)cell {
    for (UIView *v in cell.contentView.subviews) {
        if ([v isKindOfClass:[UISlider class]]) return (UISlider *)v;
    }
    return nil;
}

- (void)rd_setupValueLabelInCell:(UITableViewCell *)cell {
    Class sliderCellCls = NSClassFromString(@"PSSliderCell");
    if (!sliderCellCls || ![cell isKindOfClass:sliderCellCls]) return;
    UISlider *slider = [self rd_sliderInCell:cell];
    if (!slider) return;

    // Hide the native (%.1f, corner-clipped) label. Identify it as any non-title
    // UILabel whose text is purely numeric; detailTextLabel is the usual one.
    NSCharacterSet *bad = [[NSCharacterSet characterSetWithCharactersInString:@"0123456789.-"] invertedSet];
    NSMutableArray *numericLabels = [NSMutableArray array];
    UILabel *detail = cell.detailTextLabel;
    if (detail) [numericLabels addObject:detail];
    for (UIView *v in cell.contentView.subviews) {
        if ([v isKindOfClass:[UILabel class]] &&
            v != cell.textLabel &&
            ![numericLabels containsObject:v]) {
            [numericLabels addObject:v];
        }
    }
    for (UILabel *lab in numericLabels) {
        NSString *t = lab.text ?: @"";
        if (t.length > 0 && [t rangeOfCharacterFromSet:bad].location == NSNotFound) {
            lab.hidden = YES;
        }
    }

    // Install our own persistent label once per cell (cells are reused).
    UILabel *mine = objc_getAssociatedObject(cell, &kRDValueLabelKey);
    if (!mine) {
        mine = [[UILabel alloc] init];
        mine.font = [UIFont systemFontOfSize:13.0];
        mine.textColor = [UIColor darkGrayColor];
        mine.textAlignment = NSTextAlignmentRight;
        mine.translatesAutoresizingMaskIntoConstraints = NO;
        [cell.contentView addSubview:mine];
        // trailing -16 keeps it inside the grouped cell, clear of the corner;
        // >= 28pt width fits 2-3 digits; centre vertically like the native one.
        [NSLayoutConstraint activateConstraints:@[
            [mine.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-16.0],
            [mine.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
            [mine.widthAnchor constraintGreaterThanOrEqualToConstant:28.0],
        ]];
        objc_setAssociatedObject(cell, &kRDValueLabelKey, mine, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    if (!objc_getAssociatedObject(cell, &kRDSliderHookedKey)) {
        // The system target (added at cell init) updates the now-hidden native
        // label; ours updates our own label from slider.value afterwards.
        [slider addTarget:self
                   action:@selector(rd_sliderValueChanged:)
         forControlEvents:UIControlEventValueChanged];
        objc_setAssociatedObject(cell, &kRDSliderHookedKey, @YES,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [self rd_updateValueLabelInCell:cell];

    RDPrefsLog(@"cell=%@ nativeLabels=%lu value=%.1f",
               NSStringFromClass([cell class]), (unsigned long)numericLabels.count, slider.value);
}

- (void)rd_sliderValueChanged:(UISlider *)slider {
    UIView *cv = slider.superview;
    id cell = cv.superview;
    if ([cell isKindOfClass:[UITableViewCell class]]) {
        [self rd_updateValueLabelInCell:(UITableViewCell *)cell];
    }
}

- (void)rd_updateValueLabelInCell:(UITableViewCell *)cell {
    UILabel *mine = objc_getAssociatedObject(cell, &kRDValueLabelKey);
    if (!mine) return;
    UISlider *slider = [self rd_sliderInCell:cell];
    if (!slider) return;
    long iv = (long)(slider.value + 0.5);
    NSString *s = [NSString stringWithFormat:@"%ld", iv];
    if (![s isEqualToString:mine.text]) {
        mine.text = s;
        RDPrefsLog(@"value label=%@ frame=%@", s, NSStringFromCGRect(mine.frame));
    }
}

@end
