#import "PXAmbientPlex.h"
#import "PXServer.h"
#import "PXItem.h"
#import "PXPlex.h"

@implementation PXAmbientLayer (Plex)

- (void)showItem:(PXItem *)item {
    NSURL *art = item.art ? [item.server artURL:item.art width:(int)self.artSize.width height:(int)self.artSize.height blur:0] : nil;
    [self showColors:item.raw[@"UltraBlurColors"] artURL:art];
}

@end
