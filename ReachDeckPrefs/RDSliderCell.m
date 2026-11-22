#import "RDSliderCell.h"
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>
#import <math.h>

#define RD_NOTIFY "com.zlhkf.ReachDeck.settings"
#define RDPlistPath ([[NSFileManager defaultManager] fileExistsAtPath:@"/var/mobile/Library/Preferences"] ? @"/var/mobile/Library/Preferences/com.zlhkf.ReachDeck.plist" : @"/var/jb/var/mobile/Library/Preferences/com.zlhkf.ReachDeck.plist")

typedef NS_ENUM(NSInteger, RDValueStyle) {
    RDValueStylePlain = 0,   // "16"
    RDValueStylePercent,     // "72%"
    RDValueStylePoints,      // "16 pt"
};

@interface RDSliderCell ()
@property(nonatomic, strong) UILabel *titleLabelView;
@property(nonatomic, strong) UILabel *valueLabel;
@property(nonatomic, strong) UISlider *slider;
@property(nonatomic, copy) NSString *preferenceKey;
@property(nonatomic, assign) CGFloat minimumValue;
@property(nonatomic, assign) CGFloat maximumValue;
@property(nonatomic, assign) CGFloat defaultValue;
@property(nonatomic, assign) CGFloat inputStep;
@property(nonatomic, assign) RDValueStyle valueStyle;
@end

@implementation RDSliderCell

+ (CGFloat)preferredHeightForWidth:(CGFloat)width {
    (void)width;
    return 76.0;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style
              reuseIdentifier:(NSString *)reuseIdentifier
                    specifier:(PSSpecifier *)specifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier specifier:specifier];
    if (self) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        // Custom layout owns the caption; hide the inherited labels so there is
        // no duplicate text under the slider.
        self.textLabel.hidden = YES;
        self.detailTextLabel.hidden = YES;

        _preferenceKey = [[specifier propertyForKey:@"preferenceKey"] copy];
        _minimumValue = [[specifier propertyForKey:@"minimumValue"] doubleValue];
        _maximumValue = [[specifier propertyForKey:@"maximumValue"] doubleValue];
        _defaultValue = [[specifier propertyForKey:@"defaultValue"] doubleValue];
        _inputStep = [[specifier propertyForKey:@"inputStep"] doubleValue];
        if (_inputStep <= 0.0 || !isfinite(_inputStep)) _inputStep = 1.0;

        NSString *styleName = [specifier propertyForKey:@"valueStyle"] ?: @"plain";
        if ([styleName isEqualToString:@"percent"]) {
            _valueStyle = RDValueStylePercent;
        } else if ([styleName isEqualToString:@"points"]) {
            _valueStyle = RDValueStylePoints;
        } else {
            _valueStyle = RDValueStylePlain;
        }

        _titleLabelView = [[UILabel alloc] initWithFrame:CGRectZero];
        _titleLabelView.text = specifier.name;
        _titleLabelView.font = [UIFont systemFontOfSize:16.0];
        _titleLabelView.textColor = [UIColor labelColor];
        [self.contentView addSubview:_titleLabelView];

        // Monospaced digits + right alignment: the value sits at the top-right,
        // well clear of the grouped cell's rounded corner (nothing gets clipped).
        _valueLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _valueLabel.font = [UIFont monospacedDigitSystemFontOfSize:13.0 weight:UIFontWeightRegular];
        _valueLabel.textColor = [UIColor secondaryLabelColor];
        _valueLabel.textAlignment = NSTextAlignmentRight;
        [self.contentView addSubview:_valueLabel];

        _slider = [[UISlider alloc] initWithFrame:CGRectZero];
        _slider.minimumValue = (float)_minimumValue;
        _slider.maximumValue = (float)_maximumValue;
        [_slider setValue:(float)[self normalizedValue:[self readPreference]] animated:NO];
        [_slider addTarget:self action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];
        [_slider addTarget:self action:@selector(sliderReleased:)
          forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside];
        [self.contentView addSubview:_slider];

        [self updateValueLabel];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.textLabel.hidden = YES;
    self.detailTextLabel.hidden = YES;
    CGFloat width = CGRectGetWidth(self.contentView.bounds);
    // Title + value share the first line, slider owns the second. Same geometry
    // as Lumen's slider rows so the caption never collides with the value.
    self.titleLabelView.frame = CGRectMake(16.0, 8.0, width * 0.55, 22.0);
    self.valueLabel.frame = CGRectMake(16.0 + width * 0.55, 8.0, width * 0.45 - 32.0, 22.0);
    self.slider.frame = CGRectMake(16.0, 36.0, width - 32.0, 32.0);
}

- (CGFloat)readPreference {
    NSDictionary *settings = [NSDictionary dictionaryWithContentsOfFile:RDPlistPath];
    id value = settings[self.preferenceKey];
    if ([value isKindOfClass:[NSNumber class]]) return [(NSNumber *)value doubleValue];
    return self.defaultValue;
}

- (void)writePreference:(CGFloat)value {
    if (self.preferenceKey.length == 0) return;
    NSMutableDictionary *settings = [NSMutableDictionary dictionary];
    [settings addEntriesFromDictionary:[NSDictionary dictionaryWithContentsOfFile:RDPlistPath]];
    settings[self.preferenceKey] = @(value);
    [settings writeToFile:RDPlistPath atomically:YES];
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         CFSTR(RD_NOTIFY), NULL, NULL, TRUE);
}

- (CGFloat)normalizedValue:(CGFloat)value {
    if (!isfinite(value)) value = self.defaultValue;
    value = MAX(self.minimumValue, MIN(self.maximumValue, value));
    CGFloat step = self.inputStep;
    if (step > 0.0 && isfinite(step)) {
        // Snap on an integer grid, then undo the binary-float residue that
        // step * index introduces (0.1 * 3 = 0.30000000000000004), so the plist
        // stores 0.3 instead of a 17-digit ghost and the caption reads cleanly.
        double snapped = round((double)value / (double)step) * (double)step;
        snapped = round(snapped * 1000.0) / 1000.0;
        value = (CGFloat)snapped;
    }
    return MAX(self.minimumValue, MIN(self.maximumValue, value));
}

- (NSString *)formattedValue:(CGFloat)value {
    // 0.3.5: a sub-unit inputStep means the value can legitimately sit between
    // two integers. This used to lround() unconditionally, so with a 0.1 step
    // the caption still printed "1 pt" for anything from 0.5 to 1.4 and the
    // slider looked like it could not do decimals at all.
    NSString *number = nil;
    if (self.inputStep > 0.0 && self.inputStep < 1.0) {
        int decimals = (self.inputStep < 0.1) ? 2 : 1;
        number = [NSString stringWithFormat:@"%.*f", decimals, (double)value];
    } else {
        number = [NSString stringWithFormat:@"%ld", (long)lround(value)];
    }
    switch (self.valueStyle) {
        case RDValueStylePercent:
            return [number stringByAppendingString:@"%"];
        case RDValueStylePoints:
            return [number stringByAppendingString:@" pt"];
        case RDValueStylePlain:
        default:
            return number;
    }
}

- (void)updateValueLabel {
    self.valueLabel.text = [self formattedValue:[self normalizedValue:self.slider.value]];
}

- (void)sliderChanged:(UISlider *)slider {
    slider.value = (float)[self normalizedValue:slider.value];
    [self updateValueLabel];
}

- (void)sliderReleased:(UISlider *)slider {
    (void)slider;
    [self writePreference:[self normalizedValue:self.slider.value]];
}

@end
