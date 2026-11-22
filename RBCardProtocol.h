// ReachDeck — pluggable card protocol
// Cards are plain Objective-C objects. The container owns them, asks for a view,
// and calls refresh whenever the Reachability window appears or a Darwin event fires.
// Keep this header dependency-free so future cards can be added without touching the host.

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@protocol RBCard <NSObject>

@required
/// Card priority. Lower number renders first. Default ordering handled by container.
@property (nonatomic, readonly) NSInteger rbPriority;
/// Unique stable key, used for enable/disable in prefs and for state files.
@property (nonatomic, readonly, copy) NSString *rbIdentifier;
/// The view mounted into the Reachability container. Built once, reused across refreshes.
@property (nonatomic, readonly, strong) UIView *rbView;

@optional
/// Called on container appear and on any registered Darwin notification.
- (void)rbRefresh;
/// Called when the card is about to be removed / container torn down.
- (void)rbWillUnmount;
/// Whether the card wants the long-press "pin" gesture to defeat the 0.8s keep-alive.
@property (nonatomic, readonly) BOOL rbWantsPin;
/// 0.3.0: identity shown in the vertical card rail (SF Symbol name + label).
@property (nonatomic, readonly, copy) NSString *rbRailImageName;
@property (nonatomic, readonly, copy) NSString *rbRailTitle;
/// 0.3.0: shared appearance settings applied to every card.
- (void)setStyleOpacity:(CGFloat)opacity corner:(CGFloat)corner border:(CGFloat)border compact:(BOOL)compact;

@end

NS_ASSUME_NONNULL_END
