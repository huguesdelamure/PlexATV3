// Vertical list of text rows (title + right-aligned value), with a focus
// highlight and scrolling. Used for settings, track pickers, menus.

#import <QuartzCore/QuartzCore.h>

@interface PXListRow : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *value;     // right-aligned, dimmed
@property (nonatomic, assign) BOOL checked;      // ✓ on the left
@property (nonatomic, assign) BOOL enabled;      // default YES
@property (nonatomic, copy) void (^action)(void);
+ (instancetype)title:(NSString *)title value:(NSString *)value action:(void (^)(void))action;
@end

@interface PXListLayer : CALayer
- (instancetype)initWithFrame:(CGRect)frame rowHeight:(CGFloat)rowHeight;
@property (nonatomic, copy) NSArray *rows;       // PXListRow
@property (nonatomic, assign) NSInteger focusIndex;
@property (nonatomic, assign) BOOL active;
- (BOOL)handleUp;
- (BOOL)handleDown;
- (void)activate;                                // runs the focused row action
@end
