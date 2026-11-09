#import "PXPlayQueue.h"
#import "PXItem.h"
#import "PXLog.h"

@implementation PXPlayQueue {
    NSMutableArray *_items;
}

+ (instancetype)shared {
    static PXPlayQueue *q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ q = [PXPlayQueue new]; });
    return q;
}

- (instancetype)init { if ((self = [super init])) _items = [NSMutableArray array]; return self; }

- (NSArray *)items { return [_items copy]; }

- (void)removeSame:(PXItem *)item {
    NSIndexSet *same = [_items indexesOfObjectsPassingTest:^BOOL(PXItem *o, NSUInteger i, BOOL *stop) { return [o.uniqueKey isEqual:item.uniqueKey]; }];
    [_items removeObjectsAtIndexes:same];
}

- (void)playNext:(PXItem *)item { if (!item) return; [self removeSame:item]; [_items insertObject:item atIndex:0]; PXLog(@"queue: next '%@' (%lu)", item.title, (unsigned long)_items.count); }
- (void)add:(PXItem *)item { if (!item) return; [self removeSame:item]; [_items addObject:item]; PXLog(@"queue: add '%@' (%lu)", item.title, (unsigned long)_items.count); }

- (PXItem *)popNext {
    PXItem *it = _items.firstObject;
    if (it) [_items removeObjectAtIndex:0];
    return it;
}
@end
