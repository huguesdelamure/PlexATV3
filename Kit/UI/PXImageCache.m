#import "PXImageCache.h"
#import "PXLog.h"
#import <ImageIO/ImageIO.h>
#import <CommonCrypto/CommonDigest.h>

static const NSUInteger kMemoryLimit = 40 * 1024 * 1024;     // decoded bitmaps
static const unsigned long long kDiskLimit = 250ULL * 1024 * 1024;

@interface PXImageCache ()
@property (nonatomic, strong) NSCache *memory;
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSMutableDictionary *pending;   // key -> [blocks]
@property (nonatomic, strong) dispatch_queue_t decodeQueue;
@property (nonatomic, copy) NSString *diskDir;
@end

static NSString *keyFor(NSURL *url) {
    const char *s = url.absoluteString.UTF8String;
    unsigned char md[CC_MD5_DIGEST_LENGTH];
    CC_MD5(s, (CC_LONG)strlen(s), md);
    NSMutableString *hex = [NSMutableString string];
    for (int i = 0; i < CC_MD5_DIGEST_LENGTH; i++) [hex appendFormat:@"%02x", md[i]];
    return hex;
}

// Decode + downscale into a bitmap in the GPU-friendly format, off main thread.
static CGImageRef decodeImage(NSData *data, CGSize size, CGFloat radius, CGSize fade) CF_RETURNS_RETAINED;
static CGImageRef decodeImage(NSData *data, CGSize size, CGFloat radius, CGSize fade) {
    CGImageSourceRef src = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    if (!src) return NULL;
    NSDictionary *opts = @{ (id)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
                            (id)kCGImageSourceCreateThumbnailWithTransform: @YES,
                            (id)kCGImageSourceThumbnailMaxPixelSize: @(MAX(size.width, size.height)) };
    CGImageRef thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, (__bridge CFDictionaryRef)opts);
    CFRelease(src);
    if (!thumb) return NULL;
    size_t w = CGImageGetWidth(thumb), h = CGImageGetHeight(thumb);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(NULL, w, h, 8, 0, cs,
                                             kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
    CGColorSpaceRelease(cs);
    if (!ctx) return thumb;
    if (radius > 0) {
        // Aspect-fill into the requested size, clipped to a rounded rect.
        CGFloat tw = size.width, th = size.height;
        CGContextRelease(ctx);
        cs = CGColorSpaceCreateDeviceRGB();
        ctx = CGBitmapContextCreate(NULL, (size_t)tw, (size_t)th, 8, 0, cs, kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
        CGColorSpaceRelease(cs);
        CGPathRef clip = CGPathCreateWithRoundedRect(CGRectMake(0, 0, tw, th), radius, radius, NULL);
        CGContextAddPath(ctx, clip);
        CGContextClip(ctx);
        CGPathRelease(clip);
        CGFloat k = MAX(tw / w, th / h);
        CGContextSetInterpolationQuality(ctx, kCGInterpolationHigh);
        CGContextDrawImage(ctx, CGRectMake((tw - w * k) / 2, (th - h * k) / 2, w * k, h * k), thumb);
    } else {
        CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), thumb);
    }
    if (fade.width > 0 || fade.height > 0) {
        // Multiply alpha by gradients (destination-in keeps color, scales alpha).
        size_t cw = CGBitmapContextGetWidth(ctx), ch = CGBitmapContextGetHeight(ctx);
        CGColorSpaceRef gray = CGColorSpaceCreateDeviceGray();
        CGFloat comps[] = { 0, 0,  0, 1 };   // (gray, alpha) pairs: transparent -> opaque
        CGFloat locs[] = { 0, 1 };
        CGGradientRef g = CGGradientCreateWithColorComponents(gray, comps, locs, 2);
        CGContextSetBlendMode(ctx, kCGBlendModeDestinationIn);
        if (fade.width > 0) {
            // Left edge: transparent at x=0, opaque at x=fade.width*cw.
            CGContextSaveGState(ctx);
            CGContextClipToRect(ctx, CGRectMake(0, 0, cw * fade.width, ch));
            CGContextDrawLinearGradient(ctx, g, CGPointMake(0, 0), CGPointMake(cw * fade.width, 0), 0);
            CGContextRestoreGState(ctx);
        }
        if (fade.height > 0) {
            // Bottom edge (bitmap origin is bottom-left): transparent at y=0.
            CGContextSaveGState(ctx);
            CGContextClipToRect(ctx, CGRectMake(0, 0, cw, ch * fade.height));
            CGContextDrawLinearGradient(ctx, g, CGPointMake(0, 0), CGPointMake(0, ch * fade.height), 0);
            CGContextRestoreGState(ctx);
        }
        CGGradientRelease(g);
        CGColorSpaceRelease(gray);
    }
    CGImageRelease(thumb);
    CGImageRef out = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    return out;
}

@implementation PXImageCache

+ (instancetype)shared {
    static PXImageCache *c;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ c = [PXImageCache new]; });
    return c;
}

- (instancetype)init {
    if ((self = [super init])) {
        _memory = [NSCache new];
        _memory.totalCostLimit = kMemoryLimit;
        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
        cfg.HTTPMaximumConnectionsPerHost = 4;
        cfg.URLCache = nil;
        cfg.timeoutIntervalForRequest = 30;
        _session = [NSURLSession sessionWithConfiguration:cfg];
        _pending = [NSMutableDictionary dictionary];
        _decodeQueue = dispatch_queue_create("plexatv.decode", DISPATCH_QUEUE_SERIAL);
        _diskDir = [PXDataDir() stringByAppendingPathComponent:@"img"];
        [[NSFileManager defaultManager] createDirectoryAtPath:_diskDir withIntermediateDirectories:YES attributes:nil error:NULL];
        // Memory warnings: drop decoded bitmaps (they are cheap to re-decode from disk).
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidReceiveMemoryWarningNotification object:nil
                                                           queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) {
            PXLog(@"images: memory warning, flushing cache");
            [self.memory removeAllObjects];
        }];
    }
    return self;
}

- (CGImageRef)cachedImageForURL:(NSURL *)url {
    return [self cachedImageForURL:url radius:0];
}

- (CGImageRef)cachedImageForURL:(NSURL *)url radius:(CGFloat)radius {
    if (!url) return NULL;
    return (__bridge CGImageRef)[self.memory objectForKey:[keyFor(url) stringByAppendingFormat:@"-r%.0f", radius]];
}

- (void)finish:(NSString *)key image:(CGImageRef)img {
    if (img) {
        size_t cost = CGImageGetBytesPerRow(img) * CGImageGetHeight(img);
        [self.memory setObject:(__bridge id)img forKey:key cost:cost];
    }
    NSArray *blocks = self.pending[key];
    [self.pending removeObjectForKey:key];
    for (PXImageBlock b in blocks) b(img);
}

- (void)loadURL:(NSURL *)url size:(CGSize)size done:(PXImageBlock)done {
    [self loadURL:url size:size radius:0 done:done];
}

- (void)loadURL:(NSURL *)url size:(CGSize)size radius:(CGFloat)radius done:(PXImageBlock)done {
    [self loadURL:url size:size radius:radius fade:CGSizeZero done:done];
}

- (void)loadURL:(NSURL *)url size:(CGSize)size fadeLeft:(CGFloat)left fadeBottom:(CGFloat)bottom done:(PXImageBlock)done {
    [self loadURL:url size:size radius:0 fade:CGSizeMake(left, bottom) done:done];
}

- (void)loadURL:(NSURL *)url size:(CGSize)size radius:(CGFloat)radius fade:(CGSize)fade done:(PXImageBlock)done {
    if (!url) { done(NULL); return; }
    NSString *fileKey = keyFor(url);
    NSString *key = [fileKey stringByAppendingFormat:@"-r%.0f", radius];
    if (fade.width > 0 || fade.height > 0) key = [key stringByAppendingFormat:@"-f%.2f-%.2f", fade.width, fade.height];
    CGImageRef cached = (__bridge CGImageRef)[self.memory objectForKey:key];
    if (cached) { done(cached); return; }
    NSMutableArray *waiting = self.pending[key];
    if (waiting) { [waiting addObject:[done copy]]; return; }
    self.pending[key] = [NSMutableArray arrayWithObject:[done copy]];

    NSString *path = [self.diskDir stringByAppendingPathComponent:fileKey];
    dispatch_async(self.decodeQueue, ^{
        NSData *disk = [NSData dataWithContentsOfFile:path];
        if (disk) {
            CGImageRef img = decodeImage(disk, size, radius, fade);
            dispatch_async(dispatch_get_main_queue(), ^{ [self finish:key image:img]; CGImageRelease(img); });
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [[self.session dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
                NSInteger code = [(NSHTTPURLResponse *)resp statusCode];
                if (err || code != 200 || !data.length) {
                    PXLog(@"images: %@ -> HTTP %ld %@", url.host, (long)code, err.localizedDescription ?: @"");
                    dispatch_async(dispatch_get_main_queue(), ^{ [self finish:key image:NULL]; });
                    return;
                }
                dispatch_async(self.decodeQueue, ^{
                    [data writeToFile:path atomically:NO];
                    CGImageRef img = decodeImage(data, size, radius, fade);
                    dispatch_async(dispatch_get_main_queue(), ^{ [self finish:key image:img]; CGImageRelease(img); });
                });
            }] resume];
        });
    });
}

- (void)trimDiskCache {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        NSURL *dir = [NSURL fileURLWithPath:self.diskDir];
        NSArray *files = [fm contentsOfDirectoryAtURL:dir includingPropertiesForKeys:@[ NSURLContentModificationDateKey, NSURLFileSizeKey ]
                                              options:0 error:NULL];
        unsigned long long total = 0;
        for (NSURL *f in files) total += [[f resourceValuesForKeys:@[ NSURLFileSizeKey ] error:NULL][NSURLFileSizeKey] unsignedLongLongValue];
        if (total <= kDiskLimit) return;
        NSArray *sorted = [files sortedArrayUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) {
            NSDate *da = [a resourceValuesForKeys:@[ NSURLContentModificationDateKey ] error:NULL][NSURLContentModificationDateKey];
            NSDate *db = [b resourceValuesForKeys:@[ NSURLContentModificationDateKey ] error:NULL][NSURLContentModificationDateKey];
            return [da compare:db];
        }];
        for (NSURL *f in sorted) {
            if (total <= kDiskLimit * 0.8) break;
            total -= [[f resourceValuesForKeys:@[ NSURLFileSizeKey ] error:NULL][NSURLFileSizeKey] unsignedLongLongValue];
            [fm removeItemAtURL:f error:NULL];
        }
        PXLog(@"images: disk cache trimmed to %llu MB", total / 1024 / 1024);
    });
}

@end
