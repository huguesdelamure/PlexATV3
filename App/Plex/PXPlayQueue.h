// "Up next" queue of the app: titles added from their page ("Lire ensuite",
// "Ajouter à la file"), played one after the other when a video ends.

#import <Foundation/Foundation.h>
@class PXItem;

@interface PXPlayQueue : NSObject
+ (instancetype)shared;
- (void)playNext:(PXItem *)item;    // first in line
- (void)add:(PXItem *)item;         // last in line
- (PXItem *)popNext;                // nil when empty
@property (nonatomic, readonly) NSArray *items;
@end
