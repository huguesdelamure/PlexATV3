// "Découvrir" home tab: editorial rows of plex.tv (trending, coming soon…)
// from discover.provider.plex.tv. A title opens its page on one of the
// servers when it is there, else its online page (watchlist).

#import "PXRouter.h"
#import "PXUI.h"
#import "PXShelfLayer.h"
#import "PXAmbientPlex.h"
#import "PXPlex.h"
#import "PXServer.h"
#import "PXItem.h"
#import "PXLog.h"

@interface PXDiscoverScreen : PXScreen
@end

@implementation PXDiscoverScreen {
    PXAmbientLayer *_ambient;
    CALayer *_rows;
    NSMutableArray *_shelves;
    NSInteger _index;
    CATextLayer *_status;
}

- (void)setup {
    _ambient = [[PXAmbientLayer alloc] initWithFrame:self.layer.bounds style:PXAmbientBlurOnly];
    [self.layer addSublayer:_ambient];
    _rows = [CALayer layer];
    _rows.anchorPoint = CGPointZero;
    _rows.position = CGPointMake(0, 140);
    [self.layer addSublayer:_rows];
    _shelves = [NSMutableArray array];
    _status = PXText(PXFontMedium(30), PXColorTextDim());
    _status.frame = CGRectMake(110, 200, 1700, 40);
    _status.string = PXL(@"Chargement…");
    [self.layer addSublayer:_status];
    PXServer *online = [PXPlex shared].onlineProvider;
    __weak PXDiscoverScreen *weak = self;
    [online get:@"/hubs/sections/home" done:^(NSDictionary *mc, NSError *err) {
        PXDiscoverScreen *me = weak;
        if (!me) return;
        if (err) { PXSetText(me->_status, err.localizedDescription); return; }
        // Rows of movies and shows only (trailers are not playable here).
        NSMutableArray *hubs = [NSMutableArray array];
        for (NSDictionary *h in mc[@"Hub"])
            if (h[@"key"] && ![h[@"type"] isEqual:@"clip"] && ![h[@"type"] isEqual:@"directory"]) [hubs addObject:h];
        [me loadHubs:hubs];
    }];
}

- (void)loadHubs:(NSArray *)hubs {
    PXServer *online = [PXPlex shared].onlineProvider;
    NSMutableArray *results = [NSMutableArray arrayWithCapacity:hubs.count];
    for (NSUInteger i = 0; i < hubs.count; i++) [results addObject:[NSNull null]];
    __block NSInteger pending = hubs.count;
    __weak PXDiscoverScreen *weak = self;
    for (NSUInteger i = 0; i < hubs.count; i++) {
        NSDictionary *h = hubs[i];
        NSString *key = h[@"key"];
        NSString *path = [key stringByAppendingString:[key containsString:@"?"] ? @"&count=20" : @"?count=20"];
        [online get:path done:^(NSDictionary *mc, NSError *err) {
            NSArray *items = [PXItem itemsWithJSON:mc[@"Metadata"]];
            if (items.count) results[i] = @{ @"title": h[@"title"] ?: @"", @"items": items };
            if (--pending == 0) [weak showRows:results];
        }];
    }
}

- (void)showRows:(NSArray *)rows {
    CGFloat y = 0;
    for (id r in rows) {
        if (r == [NSNull null]) continue;
        PXShelfLayer *s = [[PXShelfLayer alloc] initWithTitle:r[@"title"] width:1920 imageSize:CGSizeMake(170, 255) artwork:PXArtworkPoster];
        s.items = r[@"items"];
        PXNoAnim(^{ s.position = CGPointMake(0, y); [self->_rows addSublayer:s]; });
        y += s.height + 24;
        [_shelves addObject:s];
    }
    _status.hidden = _shelves.count > 0;
    if (!_shelves.count) PXSetText(_status, PXL(@"Rien à découvrir pour le moment."));
    [self updateFocus];
}

- (void)updateFocus {
    for (NSInteger i = 0; i < (NSInteger)_shelves.count; i++) [_shelves[i] setActive:self.hasFocus && i == _index];
    if (_index >= (NSInteger)_shelves.count) return;
    CGFloat y = 140 - [_shelves[_index] position].y;
    PXAnim(0.35, ^{
        self->_rows.position = CGPointMake(0, y);
        for (NSInteger i = 0; i < (NSInteger)self->_shelves.count; i++) [self->_shelves[i] setOpacity:i < self->_index ? 0 : 1];
    });
    PXItem *it = [_shelves[_index] focusedItem];
    if (it) [_ambient showItem:it];
}

- (void)focusChanged { [self updateFocus]; }

- (BOOL)handleKey:(PXKey)key {
    if (!_shelves.count) return NO;
    PXShelfLayer *s = _shelves[_index];
    switch (key) {
        case PXKeyLeft: case PXKeyRight: [s moveBy:key == PXKeyLeft ? -1 : 1]; [self updateFocus]; return YES;
        case PXKeyDown: if (_index + 1 < (NSInteger)_shelves.count) { _index++; [self updateFocus]; } return YES;
        case PXKeyUp: if (_index == 0) return NO; _index--; [self updateFocus]; return YES;   // first row: back to the tabs
        case PXKeySelect: if (s.focusedItem) [self push:PXScreenForItem(s.focusedItem)]; return YES;
        default: return NO;
    }
}

@end

PXScreen *PXDiscoverScreenNew(void) {
    PXDiscoverScreen *s = [PXDiscoverScreen new];
    s.embedded = YES;
    [s setup];
    return s;
}
