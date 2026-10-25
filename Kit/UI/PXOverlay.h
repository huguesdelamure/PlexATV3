// Side panel with a title and a list of choices, drawn over a screen.
// While visible it takes the keys (up/down/select, menu closes it).

#import <QuartzCore/QuartzCore.h>
#import "PXScreen.h"
#import "PXListLayer.h"

@interface PXOverlay : CALayer
+ (instancetype)overlayInLayer:(CALayer *)parent title:(NSString *)title rows:(NSArray *)rows;
@property (nonatomic, readonly) PXListLayer *list;
@property (nonatomic, copy) void (^onClose)(void);
- (void)close;
- (BOOL)handleKey:(PXKey)key;    // always YES while visible
@end
