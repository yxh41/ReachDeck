#import "RDIntSliderCell.h"

@implementation RDIntSliderCell {
    BOOL _rdHooked;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    UISlider *slider = [self rd_sliderView];
    if (!slider) return;
    if (!_rdHooked) {
        // The system action (added during PSSliderCell init) runs first and sets
        // the label to "%.1f"; ours is added later so the integer rewrite wins.
        [slider addTarget:self
                   action:@selector(rd_sliderValueChanged:)
         forControlEvents:UIControlEventValueChanged];
        _rdHooked = YES;
    }
    [self rd_normalizeValueLabel];
}

- (void)rd_sliderValueChanged:(UISlider *)slider {
    [self rd_normalizeValueLabel];
}

- (UISlider *)rd_sliderView {
    for (UIView *v in self.contentView.subviews) {
        if ([v isKindOfClass:[UISlider class]]) return (UISlider *)v;
    }
    return nil;
}

- (UILabel *)rd_numberLabel {
    // detailTextLabel first (what PSSliderCell typically uses), then any other
    // non-titleUILabel whose text is purely numeric. Non-numeric labels (the
    // title) are ignored so we never shift or rewrite them by mistake.
    NSMutableArray *cands = [NSMutableArray array];
    UILabel *detail = self.detailTextLabel;
    if (detail) [cands addObject:detail];
    for (UIView *v in self.contentView.subviews) {
        if ([v isKindOfClass:[UILabel class]] &&
            v != self.textLabel &&
            ![cands containsObject:v]) {
            [cands addObject:v];
        }
    }
    NSCharacterSet *bad = [[NSCharacterSet characterSetWithCharactersInString:@"0123456789.-"] invertedSet];
    for (UILabel *lab in cands) {
        NSString *t = lab.text ?: @"";
        if (t.length > 0 && [t rangeOfCharacterFromSet:bad].location == NSNotFound) {
            return lab;
        }
    }
    return nil;
}

- (void)rd_normalizeValueLabel {
    UILabel *lab = [self rd_numberLabel];
    if (!lab) return;
    double d = [lab.text doubleValue];
    NSString *s = [NSString stringWithFormat:@"%ld", (long)(d + 0.5)];
    if (![s isEqualToString:lab.text]) lab.text = s;
    // transform is applied after Auto Layout, so it won't fight the cell's
    // own constraints; -9pt clears the grouped-cell rounded corner.
    CGAffineTransform want = CGAffineTransformMakeTranslation(-9.0, 0.0);
    if (!CGAffineTransformEqualToTransform(lab.transform, want)) {
        lab.transform = want;
    }
}
@end
