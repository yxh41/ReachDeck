#import "RDAppCell.h"
#import <QuartzCore/QuartzCore.h>

static CGFloat const kRDAppCellIconSide = 32.0;
static CGFloat const kRDAppCellInset = 16.0;
static CGFloat const kRDAppCellBadgeSide = 24.0;

@interface RDAppCell ()
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UILabel *orderLabel;
@end

@implementation RDAppCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:UITableViewCellStyleDefault reuseIdentifier:reuseIdentifier];
    if (self) {
        _iconView = [[UIImageView alloc] init];
        _iconView.translatesAutoresizingMaskIntoConstraints = NO;
        _iconView.contentMode = UIViewContentModeScaleAspectFit;
        _iconView.layer.cornerRadius = 7.0;
        _iconView.layer.cornerCurve = kCACornerCurveContinuous;
        _iconView.clipsToBounds = YES;
        [self.contentView addSubview:_iconView];

        _nameLabel = [[UILabel alloc] init];
        _nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _nameLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
        _nameLabel.textColor = [UIColor labelColor];
        _nameLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        [self.contentView addSubview:_nameLabel];

        _orderLabel = [[UILabel alloc] init];
        _orderLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _orderLabel.font = [UIFont monospacedDigitSystemFontOfSize:13.0
                                                           weight:UIFontWeightSemibold];
        _orderLabel.textAlignment = NSTextAlignmentCenter;
        _orderLabel.textColor = [UIColor whiteColor];
        _orderLabel.backgroundColor = [UIColor systemBlueColor];
        _orderLabel.layer.cornerRadius = kRDAppCellBadgeSide / 2.0;
        _orderLabel.layer.cornerCurve = kCACornerCurveContinuous;
        _orderLabel.clipsToBounds = YES;
        [self.contentView addSubview:_orderLabel];

        // Auto Layout throughout, so nothing here recomputes frames inside
        // layoutSubviews (assigning a frame there schedules another pass, and a
        // cell that reschedules its own layout is a spin, not a render).
        [NSLayoutConstraint activateConstraints:@[
            [_iconView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor
                                                    constant:kRDAppCellInset],
            [_iconView.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [_iconView.widthAnchor constraintEqualToConstant:kRDAppCellIconSide],
            [_iconView.heightAnchor constraintEqualToConstant:kRDAppCellIconSide],

            [_nameLabel.leadingAnchor constraintEqualToAnchor:_iconView.trailingAnchor constant:12.0],
            [_nameLabel.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [_nameLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_orderLabel.leadingAnchor
                                                                constant:-8.0],

            [_orderLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor
                                                       constant:-kRDAppCellInset],
            [_orderLabel.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [_orderLabel.widthAnchor constraintEqualToConstant:kRDAppCellBadgeSide],
            [_orderLabel.heightAnchor constraintEqualToConstant:kRDAppCellBadgeSide],
        ]];
    }
    return self;
}

- (void)configureWithName:(NSString *)name icon:(UIImage *)icon order:(NSUInteger)order {
    self.nameLabel.text = name;
    self.iconView.image = icon;
    self.iconView.hidden = (icon == nil);
    self.orderLabel.hidden = (order == 0);
    self.orderLabel.text = order ? [NSString stringWithFormat:@"%lu", (unsigned long)order] : nil;
}

- (void)prepareForReuse {
    [super prepareForReuse];
    self.iconView.image = nil;
    self.iconView.hidden = YES;
    self.orderLabel.hidden = YES;
    self.orderLabel.text = nil;
    self.nameLabel.text = nil;
}

@end
