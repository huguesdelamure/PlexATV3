// One artwork cell: image (poster 2:3 or thumbnail 16:9), title, subtitle,
// progress bar, unwatched badge, focus animation.

#import <QuartzCore/QuartzCore.h>
@class PXItem;

typedef NS_ENUM(NSInteger, PXArtwork) { PXArtworkPoster, PXArtworkThumb };

@interface PXPosterLayer : CALayer
- (instancetype)initWithImageSize:(CGSize)size artwork:(PXArtwork)artwork;
@property (nonatomic, readonly) CGSize imageSize;
@property (nonatomic, readonly) CGFloat cellHeight;    // image + texts
@property (nonatomic, strong) PXItem *item;            // nil = placeholder
@property (nonatomic, assign) BOOL focused;            // animated
// Grow from the left edge on focus (first visible cell: stays inside the
// TV safe area instead of spilling into the margin).
@property (nonatomic, assign) BOOL anchorLeft;
@property (nonatomic, copy) NSString *titleOverride;   // e.g. episode title in a season row
@property (nonatomic, copy) NSString *subtitleOverride;
@end
