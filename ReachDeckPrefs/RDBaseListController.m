#import "RDBaseListController.h"
#import <objc/runtime.h>

#define RD_NOTIFY "com.zlhkf.ReachDeck.settings"

// rootful / rootless / roothide: probe the DIRECTORY, not the file. On a fresh
// install the plist does not exist yet; probing the file would fall through to
// /var/jb (not the roothide jbroot, so it does not exist) and every write would
// be silently lost. Keep the two files byte-for-byte identical in logic.
#define RDPlistPath ([[NSFileManager defaultManager] fileExistsAtPath:@"/var/mobile/Library/Preferences"] ? @"/var/mobile/Library/Preferences/com.zlhkf.ReachDeck.plist" : @"/var/jb/var/mobile/Library/Preferences/com.zlhkf.ReachDeck.plist")

static char kRDValueNormalizedKey;

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

#pragma mark - slider value label: integers, clear of the rounded corner

// Native PSSliderCell renders showValue with "%.1f" and pins it to the grouped
// cell's right edge where the corner clips the last digit (20.0 -> "20.C").
// We cannot subclass PSSliderCell: the roothide SDK neither ships its header
// nor exports _OBJC_CLASS_$_PSSliderCell for linking. Instead we recognise the
// cell at runtime by name and decorate it in place, using only public UIKit.

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    // PSListController (a UITableViewController data source) always implements
    // cellForRowAtIndexPath, so calling super is safe. willDisplayCell: is an
    // OPTIONAL delegate method the superclass chain may not implement.
    UITableViewCell *cell = [super tableView:tableView cellForRowAtIndexPath:indexPath];
    [self rd_normalizeSliderCell:cell];
    return cell;
}

- (void)rd_normalizeSliderCell:(UITableViewCell *)cell {
    Class sliderCellCls = NSClassFromString(@"PSSliderCell");
    if (!sliderCellCls || ![cell isKindOfClass:sliderCellCls]) return;

    UISlider *slider = nil;
    for (UIView *v in cell.contentView.subviews) {
        if ([v isKindOfClass:[UISlider class]]) { slider = (UISlider *)v; break; }
    }
    if (!slider) return;

    if (!objc_getAssociatedObject(cell, &kRDValueNormalizedKey)) {
        // The system target (added at cell init) runs first and sets "%.1f";
        // ours runs after and rewrites the label as an integer.
        [slider addTarget:self
                   action:@selector(rd_sliderValueChanged:)
         forControlEvents:UIControlEventValueChanged];
        objc_setAssociatedObject(cell, &kRDValueNormalizedKey, @YES,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [self rd_rewriteValueLabelInCell:cell];
}

- (void)rd_sliderValueChanged:(UISlider *)slider {
    UIView *cv = slider.superview;
    id cell = cv.superview;
    if ([cell isKindOfClass:[UITableViewCell class]]) {
        [self rd_rewriteValueLabelInCell:(UITableViewCell *)cell];
    }
}

- (void)rd_rewriteValueLabelInCell:(UITableViewCell *)cell {
    NSMutableArray *cands = [NSMutableArray array];
    UILabel *detail = cell.detailTextLabel;
    if (detail) [cands addObject:detail];
    for (UIView *v in cell.contentView.subviews) {
        if ([v isKindOfClass:[UILabel class]] &&
            v != cell.textLabel &&
            ![cands containsObject:v]) {
            [cands addObject:v];
        }
    }
    NSCharacterSet *bad = [[NSCharacterSet characterSetWithCharactersInString:@"0123456789.-"] invertedSet];
    for (UILabel *lab in cands) {
        NSString *t = lab.text ?: @"";
        // Only touch purely numeric labels so the slider title is never moved.
        if (t.length == 0 || [t rangeOfCharacterFromSet:bad].location != NSNotFound) continue;
        NSString *s = [NSString stringWithFormat:@"%ld", (long)([t doubleValue] + 0.5)];
        if (![s isEqualToString:t]) lab.text = s;
        // transform applies after Auto Layout, so it won't fight cell constraints;
        // -9pt clears the grouped-cell rounded corner.
        CGAffineTransform want = CGAffineTransformMakeTranslation(-9.0, 0.0);
        if (!CGAffineTransformEqualToTransform(lab.transform, want)) {
            lab.transform = want;
        }
    }
}

@end
