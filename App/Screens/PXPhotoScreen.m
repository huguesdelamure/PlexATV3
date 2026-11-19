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
    CALayer *_images[2];            // cross-fade: the new photo fades in over the old one
    NSInteger _front;               // index of the layer showing the current photo
    CALayer *_captionBar;           // dark gradient + caption, shown / hidden together
    CATextLayer *_caption;
    BOOL _slideshow;
    NSInteger _serial;              // photo asked last
    NSInteger _shownSerial;         // photo displayed (or failed): the slideshow may go on
    NSInteger _slideToken;          // invalidates a scheduled slideshow step
}

- (void)setup {
    self.layer.backgroundColor = [UIColor blackColor].CGColor;
    for (int i = 0; i < 2; i++) {
        _images[i] = [CALayer layer];
        _images[i].frame = self.layer.bounds;
        _images[i].contentsGravity = kCAGravityResizeAspect;
        _images[i].opacity = 0;
        [self.layer addSublayer:_images[i]];
    }
    // Readable over light photos: a gradient under the text, not a text
    // shadow (no shadowPath on a text layer: offscreen pass on every frame).
    CAGradientLayer *bar = [CAGradientLayer layer];
    bar.frame = CGRectMake(0, 900, 1920, 180);
    bar.colors = @[ (__bridge id)PXColorBlack(0), (__bridge id)PXColorBlack(0.55) ];
    _captionBar = bar;
    _caption = PXText(PXFontMedium(26), PXColorWhite(0.8));
    _caption.frame = CGRectMake(110, 100, 1700, 36);
    [_captionBar addSublayer:_caption];
    [self.layer addSublayer:_captionBar];
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
        if (!me || serial != me->_serial) return;
        if (img) [me display:img];
        me->_shownSerial = serial;
        [me scheduleSlide];   // a photo that fails to load does not stop the slideshow
    }];
    // Next one in the cache before it is asked for.
    if (_index + 1 < (NSInteger)_photos.count)
        [[PXImageCache shared] loadURL:photoURL(_photos[_index + 1], 1920, 1080) size:CGSizeMake(1920, 1080) done:^(CGImageRef img) {}];
    NSString *date = p.raw[@"originallyAvailableAt"] ?: @"";
    NSString *text = [NSString stringWithFormat:@"%@%@%ld / %lu", p.title.length ? p.title : @"", p.title.length ? @"   " : @"",
                      (long)_index + 1, (unsigned long)_photos.count];
    if ([date length]) text = [text stringByAppendingFormat:@"   %@", date];
    PXSetText(_caption, text);
    PXAnim(0.3, ^{ self->_captionBar.opacity = self->_slideshow ? 0 : 1; });
}

// The back layer takes the photo and fades in; the front one fades out
// while keeping its own Ken Burns motion.
- (void)display:(CGImageRef)img {
    CALayer *old = _images[_front], *next = _images[1 - _front];
    _front = 1 - _front;
    PXNoAnim(^{
        [next removeAllAnimations];
        next.transform = CATransform3DIdentity;
        next.contents = (__bridge id)img;
        next.opacity = 0;
        [self.layer insertSublayer:next below:self->_captionBar];
    });
    [self kenBurns];
    PXAnim(_slideshow ? 0.8 : 0.2, ^{ next.opacity = 1; old.opacity = 0; });
}

// Slideshow: a slow zoom and pan over each photo (direction varies).
- (void)kenBurns {
    CALayer *l = _images[_front];
    [l removeAnimationForKey:@"kenburns"];
    if (!_slideshow) { PXNoAnim(^{ l.transform = CATransform3DIdentity; }); return; }
    CGFloat dx = ((int)arc4random_uniform(3) - 1) * 40, dy = ((int)arc4random_uniform(3) - 1) * 24;
    CATransform3D end = CATransform3DTranslate(CATransform3DMakeScale(1.12, 1.12, 1), dx, dy, 0);
    CABasicAnimation *a = [CABasicAnimation animationWithKeyPath:@"transform"];
    a.fromValue = [NSValue valueWithCATransform3D:CATransform3DIdentity];
    a.toValue = [NSValue valueWithCATransform3D:end];
    a.duration = 5.5 + 0.8;   // until the next photo has faded in
    a.fillMode = kCAFillModeForwards;
    a.removedOnCompletion = NO;
    [l addAnimation:a forKey:@"kenburns"];
}

// Next photo 5 s after the current one is displayed (slow links included).
- (void)scheduleSlide {
    if (!_slideshow || _shownSerial != _serial) return;
    NSInteger token = ++_slideToken;
    __weak PXPhotoScreen *weak = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        PXPhotoScreen *me = weak;
        if (me && me->_slideshow && token == me->_slideToken) [me move:1];
    });
}

- (void)move:(NSInteger)d {
    NSInteger n = _photos.count;
    if (!n) return;
    _index = (_index + d + n) % n;
    [self show];
}

- (void)setSlideshow:(BOOL)on {
    _slideshow = on;
    _slideToken++;
    PXAnim(0.3, ^{ self->_captionBar.opacity = on ? 0 : 1; });
    [self kenBurns];
    [self scheduleSlide];
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
