// Horizontal row of pill buttons with an icon (tvOS style): translucent at
// rest, white with dark content when focused, spring scale.

#import <QuartzCore/QuartzCore.h>
#import "PXUI.h"

@interface PXButton : NSObject
@property (nonatomic, assign) PXIcon icon;
@property (nonatomic, assign) BOOL hasIcon;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) void (^action)(void);
+ (instancetype)icon:(PXIcon)icon title:(NSString *)title action:(void (^)(void))action;
+ (instancetype)title:(NSString *)title action:(void (^)(void))action;
@end

@interface PXButtonRow : CALayer
- (instancetype)initWithFrame:(CGRect)frame;
@property (nonatomic, copy) NSArray *buttons;     // PXButton (those that do not fit are dropped)
- (NSUInteger)countFitting:(NSArray *)buttons;   // how many of these fit in the row's width
@property (nonatomic, assign) NSInteger focusIndex;
@property (nonatomic, assign) BOOL active;
- (BOOL)moveBy:(NSInteger)delta;
- (void)activate;
@end
