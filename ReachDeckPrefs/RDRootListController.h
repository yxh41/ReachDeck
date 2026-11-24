#import "RDBaseListController.h"

@class PSSpecifier;

@interface RDRootListController : RDBaseListController
@property (nonatomic, strong) PSSpecifier *rdPickerLink;
@property (nonatomic, strong) PSSpecifier *rdOrderLink;
@end
