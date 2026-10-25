// Full-screen photo viewer: Left / Right to browse, Play/Pause or Select for
// the slideshow (5 s per photo, cross-fade). Images are resized to 1920x1080
// by the server (photo transcoder), so large originals cost nothing here.

#import "PXRouter.h"
#import "PXUI.h"
#import "PXImageCache.h"
#import "PXServer.h"
#import "PXItem.h"

@interface PXPhotoScreen : PXScreen
@property (nonatomic, copy) NSArray *photos;   // PXItem photos
@property (nonatomic) NSInteger index;
@end

@implementation PXPhotoScreen {
    CALayer *_image;
    CATextLayer *_caption;
    dispatch_source_t _timer;
    BOOL _slideshow;
    NSInteger _serial;
}

- (void)setup {
    self.layer.backgroundColor = [UIColor blackColor].CGColor;
    _image = [CALayer layer];
    _image.frame = self.layer.bounds;
    _image.contentsGravity = kCAGravityResizeAspect;
    [self.layer addSublayer:_image];
    _caption = PXText(PXFontMedium(26), PXColorWhite(0.8));
    _caption.frame = CGRectMake(110, 1000, 1700, 36);
    _caption.shadowOpacity = 0.8;
    _caption.shadowRadius = 4;
    _caption.shadowOffset = CGSizeZero;
    [self.layer addSublayer:_caption];
    [self show];
}

static NSURL *photoURL(PXItem *p, int w, int h) {
    NSString *key = p.part[@"key"] ?: p.thumb;
    return key ? [p.server imageURL:key width:w height:h] : nil;
}

- (void)show {
    if (_index < 0 || _index >= (NSInteger)_photos.count) return;
    PXItem *p = _photos[_index];
    NSInteger serial = ++_serial;
    __weak PXPhotoScreen *weak = self;
    [[PXImageCache shared] loadURL:photoURL(p, 1920, 1080) size:CGSizeMake(1920, 1080) done:^(CGImageRef img) {
        PXPhotoScreen *me = weak;
        if (!me || serial != me->_serial || !img) return;
        me->_image.contents = (__bridge id)img;
        PXFadeContents(me->_image, me->_slideshow ? 0.8 : 0.2);
    }];
    // Next one in the cache before it is asked for.
    if (_index + 1 < (NSInteger)_photos.count)
        [[PXImageCache shared] loadURL:photoURL(_photos[_index + 1], 1920, 1080) size:CGSizeMake(1920, 1080) done:^(CGImageRef img) {}];
    NSString *date = p.raw[@"originallyAvailableAt"] ?: @"";
    NSString *text = [NSString stringWithFormat:@"%@%@%ld / %lu", p.title.length ? p.title : @"", p.title.length ? @"   " : @"",
                      (long)_index + 1, (unsigned long)_photos.count];
    if ([date length]) text = [text stringByAppendingFormat:@"   %@", date];
    PXSetText(_caption, text);
    PXAnim(0.3, ^{ self->_caption.opacity = self->_slideshow ? 0 : 1; });
}

- (void)move:(NSInteger)d {
    NSInteger n = _photos.count;
    if (!n) return;
    _index = (_index + d + n) % n;
    [self show];
}

- (void)setSlideshow:(BOOL)on {
    _slideshow = on;
    if (_timer) { dispatch_source_cancel(_timer); _timer = nil; }
    if (on) {
        __weak PXPhotoScreen *weak = self;
        _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(_timer, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), 5 * NSEC_PER_SEC, NSEC_PER_SEC / 2);
        dispatch_source_set_event_handler(_timer, ^{ [weak move:1]; });
        dispatch_resume(_timer);
    }
    PXAnim(0.3, ^{ self->_caption.opacity = on ? 0 : 1; });
}

- (void)willDisappear { [super willDisappear]; [self setSlideshow:NO]; }

- (BOOL)handleKey:(PXKey)key {
    switch (key) {
        case PXKeyLeft: [self setSlideshow:NO]; [self move:-1]; return YES;
        case PXKeyRight: [self setSlideshow:NO]; [self move:1]; return YES;
        case PXKeySelect: case PXKeyPlayPause: [self setSlideshow:!_slideshow]; return YES;
        default: return NO;
    }
}

@end

PXScreen *PXPhotoScreenNew(NSArray *photos, NSInteger index) {
    PXPhotoScreen *s = [PXPhotoScreen new];
    s.photos = photos;
    s.index = index;
    [s setup];
    return s;
}
