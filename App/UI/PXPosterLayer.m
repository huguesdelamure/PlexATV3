#import "PXPosterLayer.h"
#import "PXServer.h"
#import <objc/runtime.h>
#import "PXUI.h"
#import "PXImageCache.h"
#import "PXPlex.h"
#import "PXItem.h"

static const CGFloat kRadius = 12;

@implementation PXPosterLayer {
    PXArtwork _artwork;
    CALayer *_card;                 // scaled on focus (image + ring + badges)
    CALayer *_shadow;               // cheap shadow: rounded shadowPath only
    CALayer *_image;
    CAShapeLayer *_ring;
    CALayer *_progressBack, *_progress;
    CALayer *_dot;
    CATextLayer *_count;
    CALayer *_title, *_subtitle;   // text drawn off the main thread
    CGFloat _subtitleY;            // below a 1- or 2-line title
    NSURL *_url;
}

static const CGFloat kTitleLine = 30;

- (instancetype)initWithImageSize:(CGSize)size artwork:(PXArtwork)artwork {
    if ((self = [super init])) {
        _imageSize = size;
        _artwork = artwork;
        _cellHeight = size.height + 80 + kTitleLine;   // title on up to 2 lines
        self.bounds = CGRectMake(0, 0, size.width, _cellHeight);
        self.anchorPoint = CGPointZero;
        CGRect ib = CGRectMake(0, 0, size.width, size.height);

        _shadow = [CALayer layer];
        _shadow.frame = ib;
        _shadow.shadowColor = [UIColor blackColor].CGColor;
        _shadow.shadowPath = [UIBezierPath bezierPathWithRoundedRect:ib cornerRadius:kRadius].CGPath;
        _shadow.shadowOffset = CGSizeMake(0, 18);
        _shadow.shadowRadius = 24;
        _shadow.shadowOpacity = 0;
        [self addSublayer:_shadow];

        _card = [CALayer layer];
        _card.frame = ib;
        [self addSublayer:_card];

        // Placeholder: rounded panel (cornerRadius on a plain color is free).
        _image = [CALayer layer];
        _image.frame = ib;
        _image.cornerRadius = kRadius;
        _image.backgroundColor = PXColorWhite(0.07);
        _image.contentsGravity = kCAGravityResize;
        [_card addSublayer:_image];

        // Progress bar inset inside the artwork (no clash with the corners).
        _progressBack = [CALayer layer];
        _progressBack.frame = CGRectMake(14, size.height - 20, size.width - 28, 6);
        _progressBack.backgroundColor = PXColorWhite(0.3);
        _progressBack.cornerRadius = 3;
        _progress = [CALayer layer];
        _progress.backgroundColor = PXColorAccent();
        _progress.cornerRadius = 3;
        _progress.anchorPoint = CGPointZero;
        [_progressBack addSublayer:_progress];
        [_card addSublayer:_progressBack];

        // Unwatched: amber dot; containers: count pill.
        _dot = [CALayer layer];
        _dot.frame = CGRectMake(size.width - 30, 12, 18, 18);
        _dot.cornerRadius = 9;
        _dot.backgroundColor = PXColorAccent();
        _dot.borderColor = PXColorBlack(0.35);
        _dot.borderWidth = 2;
        [_card addSublayer:_dot];
        _count = PXText(PXFontBold(20), PXColorBlack(0.9));
        _count.alignmentMode = kCAAlignmentCenter;
        _count.backgroundColor = PXColorAccent();
        _count.cornerRadius = 15;
        [_card addSublayer:_count];

        // Focus ring drawn just outside the artwork.
        _ring = [CAShapeLayer layer];
        _ring.path = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(ib, -5, -5) cornerRadius:kRadius + 5].CGPath;
        _ring.fillColor = NULL;
        _ring.strokeColor = PXColorText();
        _ring.lineWidth = 4;
        _ring.opacity = 0;
        [_card addSublayer:_ring];

        // White text drawn once; focus changes only the opacity (no redraw).
        _title = [CALayer layer];
        _subtitle = [CALayer layer];
        for (CALayer *l in @[ _title, _subtitle ]) {
            l.anchorPoint = CGPointZero;
            l.contentsGravity = kCAGravityTopLeft;
            l.actions = @{ @"contents": [NSNull null], @"bounds": [NSNull null] };
        }
        _subtitleY = size.height + 48;
        _title.frame = CGRectMake(2, size.height + 16, size.width - 4, 2 * kTitleLine + 2);
        _subtitle.frame = CGRectMake(2, _subtitleY, size.width - 4, 28);
        _title.opacity = 0.62;
        _subtitle.opacity = 0.4;
        [self addSublayer:_title];
        [self addSublayer:_subtitle];
        [self refresh];
    }
    return self;
}

- (void)setItem:(PXItem *)item {
    if (item == _item) return;
    _item = item;
    _titleOverride = nil;
    _subtitleOverride = nil;
    [self refresh];
}

- (void)setTitleOverride:(NSString *)t { _titleOverride = [t copy]; [self refresh]; }
- (void)setSubtitleOverride:(NSString *)t { _subtitleOverride = [t copy]; [self refresh]; }

- (NSString *)defaultSubtitle {
    PXItem *it = _item;
    if (_artwork == PXArtworkThumb && it.remainingText) {
        return it.type == PXItemEpisode ? [NSString stringWithFormat:@"%@ · %@", it.episodeCode, it.remainingText] : it.remainingText;
    }
    return it.shelfSubtitle;
}

- (void)setLabel:(CALayer *)l text:(NSString *)text font:(UIFont *)font lines:(NSInteger)lines {
    text = text ?: @"";
    if ([[l valueForKey:@"pxText"] isEqual:text]) return;
    [l setValue:text forKey:@"pxText"];
    if (!text.length) { l.contents = nil; return; }
    PXDrawTextAsync(l, text, font, PXColorText(), _imageSize.width - 4, lines, 0);
}

// Same-prefix titles ("Alvin et les Chipmunks 2/3/4") only differ at the end:
// long titles get a second line, the subtitle moves below it.
- (void)layoutTexts {
    CGFloat dy = _focused ? _imageSize.height * 0.05 + 4 : 0;
    _title.position = CGPointMake(2, _imageSize.height + 16 + dy);
    _subtitle.position = CGPointMake(2, _subtitleY + dy);
}

- (void)setAnchorLeft:(BOOL)anchorLeft {
    if (anchorLeft == _anchorLeft) return;
    _anchorLeft = anchorLeft;
    CGFloat ax = anchorLeft ? 0 : 0.5;
    PXNoAnim(^{
        for (CALayer *l in @[ self->_card, self->_shadow ]) {
            l.anchorPoint = CGPointMake(ax, 0.5);
            l.position = CGPointMake(self->_imageSize.width * ax, self->_imageSize.height / 2);
        }
    });
}

- (void)refresh {
    PXItem *it = _item;
    PXNoAnim(^{
        NSString *title = self->_titleOverride ?: it.shelfTitle;
        BOOL twoLines = PXTextWidth(title ?: @"", PXFontSemi(24)) > self->_imageSize.width - 4;
        self->_subtitleY = self->_imageSize.height + 48 + (twoLines ? kTitleLine : 0);
        [self setLabel:self->_title text:title font:PXFontSemi(24) lines:2];
        [self setLabel:self->_subtitle text:self->_subtitleOverride ?: [self defaultSubtitle] font:PXFont(20) lines:1];
        [self layoutTexts];
        double prog = it.progress;
        self->_progressBack.hidden = prog <= 0;
        self->_progress.bounds = CGRectMake(0, 0, self->_progressBack.bounds.size.width * prog, 6);
        BOOL container = it.type == PXItemShow || it.type == PXItemSeason;
        NSInteger left = container ? it.unwatchedLeaves : 0;
        self->_dot.hidden = !it || container || it.watched || prog > 0;
        self->_count.hidden = left <= 0 || it.watched;
        if (left > 0) {
            NSString *s = [@(left) stringValue];
            CGFloat w = MAX(30, PXTextWidth(s, PXFontBold(20)) + 18);
            self->_count.frame = CGRectMake(self->_imageSize.width - w - 10, 10, w, 30);
            PXSetText(self->_count, s);
        }
    });
    // URL built once per item and size (string formatting + escaping per cell refresh).
    NSString *urlKey = [NSString stringWithFormat:@"pxURL%d%.0fx%.0f", (int)_artwork, _imageSize.width, _imageSize.height];
    NSURL *url = it ? objc_getAssociatedObject(it, NSSelectorFromString(urlKey)) : nil;
    if (it && !url) {
        NSString *path = _artwork == PXArtworkThumb ? it.landscapePath : it.posterPath;
        url = [it.server imageURL:path width:(int)_imageSize.width height:(int)_imageSize.height];
        if (url) objc_setAssociatedObject(it, NSSelectorFromString(urlKey), url, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if ([url isEqual:_url] && _image.contents) return;
    _url = url;
    CGImageRef cached = [[PXImageCache shared] cachedImageForURL:url radius:kRadius];
    PXNoAnim(^{
        self->_image.contents = (__bridge id)cached;
        self->_image.backgroundColor = cached ? NULL : PXColorWhite(0.07);
    });
    if (cached || !url) return;
    __weak PXPosterLayer *weak = self;
    [[PXImageCache shared] loadURL:url size:_imageSize radius:kRadius done:^(CGImageRef img) {
        PXPosterLayer *me = weak;
        if (!me || ![url isEqual:me->_url] || !img) return;
        PXFadeContents(me->_image, 0.25);
        PXNoAnim(^{ me->_image.contents = (__bridge id)img; me->_image.backgroundColor = NULL; });
    }];
}

- (void)setFocused:(BOOL)focused {
    if (focused == _focused) return;
    _focused = focused;
    CGFloat k = focused ? 1.1 : 1.0;
    self.zPosition = focused ? 10 : 0;
    PXSpringScale(_card, k);
    PXSpringScale(_shadow, k);
    PXAnim(0.25, ^{
        self->_shadow.shadowOpacity = focused ? 0.75 : 0;
        self->_ring.opacity = focused ? 1 : 0;
        [self layoutTexts];
        self->_title.opacity = focused ? 1.0 : 0.62;
        self->_subtitle.opacity = focused ? 0.62 : 0.4;
    });
    if (focused && _image.contents) PXGlossSweep(_card, kRadius);
}

@end
