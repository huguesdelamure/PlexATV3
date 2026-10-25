// Plex convenience on top of the kit ambient background.

#import "PXAmbientLayer.h"
@class PXItem;

@interface PXAmbientLayer (Plex)
- (void)showItem:(PXItem *)item;   // UltraBlurColors + backdrop art of the item
@end
