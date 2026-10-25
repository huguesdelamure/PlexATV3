// Horizontal row of artwork cells with a title, horizontal scrolling and cell
// recycling (only the visible cells and a small margin exist as layers).

#import <QuartzCore/QuartzCore.h>
#import "PXPosterLayer.h"

@interface PXShelfLayer : CALayer
- (instancetype)initWithTitle:(NSString *)title width:(CGFloat)width
                    imageSize:(CGSize)size artwork:(PXArtwork)artwork;
@property (nonatomic, copy) NSArray *items;          // PXItem
@property (nonatomic, readonly) NSInteger focusIndex;
@property (nonatomic, assign) BOOL active;           // has the focus
@property (nonatomic, readonly) CGFloat height;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, assign) CGFloat leftMargin;    // default 110
// Optional per-cell customisation (e.g. episode titles in a season row).
@property (nonatomic, copy) void (^configure)(PXPosterLayer *cell, id item, NSInteger index);
- (BOOL)moveBy:(NSInteger)delta;                     // NO at the edges
- (void)setFocusIndex:(NSInteger)index animated:(BOOL)animated;
- (id)focusedItem;
- (void)reloadCells;                                 // items changed in place
@end
