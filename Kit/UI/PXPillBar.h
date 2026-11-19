// Row of rounded text pills (home tabs, library filters, seasons): one pill
// selected (panel background), one focused (white, slightly larger).

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

@interface PXPillBar : CALayer
- (instancetype)initWithHeight:(CGFloat)height;
// Set before the titles: the pills are laid out when the titles are set.
@property (nonatomic, strong) UIFont *font;          // default semibold 24
@property (nonatomic, assign) CGFloat padding;       // added to the text width (both sides), default 40
@property (nonatomic, assign) CGFloat gap;           // between pills, default 10
@property (nonatomic, copy) NSArray *titles;         // rebuilds the pills
@property (nonatomic, readonly) NSArray *pills;      // CALayer per title (frames, extra badges)
// Backgrounds, nil = none. The focused pill is always white.
@property (nonatomic, strong) UIColor *selectedColor;   // default panel strong
@property (nonatomic, strong) UIColor *idleColor;       // default none
// -1: no pill selected / focused.
- (void)setSelected:(NSInteger)selected focused:(NSInteger)focused;
@end
