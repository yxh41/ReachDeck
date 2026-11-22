#import "RDAppCell.h"
#import <Preferences/PSSpecifier.h>

static CGFloat const kRDAppCellIconSide = 29.0;
static CGFloat const kRDAppCellInset = 16.0;

@implementation RDAppCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style
              reuseIdentifier:(NSString *)reuseIdentifier
                    specifier:(PSSpecifier *)specifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier specifier:specifier];
    if (self) {
        self.tintColor = [UIColor systemBlueColor];
    }
    return self;
}

- (void)refreshCellContentsWithSpecifier:(PSSpecifier *)specifier {
    [super refreshCellContentsWithSpecifier:specifier];

    NSString *label = [specifier propertyForKey:@"label"];
    if ([label isKindOfClass:[NSString class]]) self.textLabel.text = label;

    UIImage *icon = [specifier propertyForKey:@"icon"];
    self.imageView.image = [icon isKindOfClass:[UIImage class]] ? icon : nil;
    self.imageView.hidden = (self.imageView.image == nil);

    BOOL on = [[specifier propertyForKey:@"selected"] boolValue];
    self.accessoryType = on ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
}

// PSTableCell lays the inherited labels out for a plain text row. The icon needs
// a fixed square and the title has to move right of it, otherwise a 512px
// artwork gets scaled to the cell height and the label collides with it.
- (void)layoutSubviews {
    [super layoutSubviews];

    CGFloat height = CGRectGetHeight(self.contentView.bounds);
    if (self.imageView.image) {
        CGRect iconFrame = CGRectMake(kRDAppCellInset,
                                      (height - kRDAppCellIconSide) / 2.0,
                                      kRDAppCellIconSide,
                                      kRDAppCellIconSide);
        // Only write when it actually differs: assigning a frame unconditionally
        // inside layoutSubviews schedules another layout pass, and a cell that
        // keeps rescheduling its own layout is a spin, not a render.
        if (!CGRectEqualToRect(self.imageView.frame, iconFrame)) {
            self.imageView.frame = iconFrame;
        }
        self.imageView.contentMode = UIViewContentModeScaleAspectFit;
        self.imageView.layer.cornerRadius = 6.5;
        self.imageView.clipsToBounds = YES;
    }

    UILabel *title = self.textLabel;
    if (!title || title.hidden) return;
    CGFloat left = self.imageView.image
        ? CGRectGetMaxX(self.imageView.frame) + 12.0
        : kRDAppCellInset;
    CGRect frame = title.frame;
    frame.origin.x = left;
    frame.size.width = MAX(0.0, CGRectGetWidth(self.contentView.bounds) - left - 52.0);
    if (!CGRectEqualToRect(title.frame, frame)) title.frame = frame;
}

@end
