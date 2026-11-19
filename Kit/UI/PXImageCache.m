#import "PXImageCache.h"
#import "PXLog.h"
#import <ImageIO/ImageIO.h>
#import <CommonCrypto/CommonDigest.h>
#import <sys/time.h>

static const NSUInteger kMemoryLimit = 40 * 1024 * 1024;     // decoded bitmaps
static const unsigned long long kDiskLimit = 250ULL * 1024 * 1024;
static const NSTimeInterval kRetryDelay = 30;                 // after a failed download

@interface PXImageCache ()
@property (nonatomic, strong) NSCache *memory;
@property (atomic, strong) NSURLSession *session;          // replaced by -setTrustDelegate:
@property (nonatomic, strong) NSMutableDictionary *pending;     // memory key -> [image blocks]
@property (nonatomic, strong) NSMutableDictionary *downloads;   // file key -> [data blocks]
@property (nonatomic, strong) NSMutableDictionary *failures;    // file key -> date of the failure
@property (nonatomic, strong) dispatch_queue_t decodeQueue;
@property (nonatomic, copy) NSString *diskDir;
@end

static NSString *md5Hex(NSString *string) {
    const char *s = string.UTF8String ?: "";
    unsigned char md[CC_MD5_DIGEST_LENGTH];
    CC_MD5(s, (CC_LONG)strlen(s), md);
    NSMutableString *hex = [NSMutableString string];
    for (int i = 0; i < CC_MD5_DIGEST_LENGTH; i++) [hex appendFormat:@"%02x", md[i]];
    return hex;
}

// Source (URL fragment, else host) + path + query without X-Plex-Token, see
// PXImageCache.h. Memoised: called for every cell shown.
static NSString *keyFor(NSURL *url) {
    static NSCache *keys;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ keys = [NSCache new]; keys.countLimit = 2000; });
    NSString *key = [keys objectForKey:url];
    if (key) return key;
    NSURLComponents *c = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    if (c) {
        NSMutableArray *query = [NSMutableArray array];
        for (NSString *q in [c.percentEncodedQuery componentsSeparatedByString:@"&"])
            if (q.length && ![q hasPrefix:@"X-Plex-Token="]) [query addObject:q];
        NSString *source = c.percentEncodedFragment.length ? c.percentEncodedFragment : (c.host ?: @"");
        key = md5Hex([NSString stringWithFormat:@"%@|%@?%@", source, c.percentEncodedPath ?: @"", [query componentsJoinedByString:@"&"]]);
    } else {
        key = md5Hex(url.absoluteString);
    }
    [keys setObject:key forKey:url];
    return key;
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
    // Rounded corners: aspect-fill into the requested size; else the thumbnail size.
    BOOL rounded = radius > 0 && size.width >= 1 && size.height >= 1;
    size_t cw = rounded ? (size_t)size.width : w, ch = rounded ? (size_t)size.height : h;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(NULL, cw, ch, 8, 0, cs, kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
    CGColorSpaceRelease(cs);
    if (!ctx) return thumb;   // decoded, just not redrawn
    if (rounded) {
        CGPathRef clip = CGPathCreateWithRoundedRect(CGRectMake(0, 0, cw, ch), radius, radius, NULL);
        CGContextAddPath(ctx, clip);
        CGContextClip(ctx);
        CGPathRelease(clip);
        CGFloat k = MAX((CGFloat)cw / w, (CGFloat)ch / h);
        CGContextSetInterpolationQuality(ctx, kCGInterpolationHigh);
        CGContextDrawImage(ctx, CGRectMake((cw - w * k) / 2, (ch - h * k) / 2, w * k, h * k), thumb);
    } else {
        CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), thumb);
    }
    if (fade.width > 0 || fade.height > 0) {
        // Multiply alpha by gradients (destination-in keeps color, scales alpha).
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

static NSURLSessionConfiguration *sessionConfiguration(void) {
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
    cfg.HTTPMaximumConnectionsPerHost = 4;
    cfg.URLCache = nil;
    cfg.timeoutIntervalForRequest = 30;
    return cfg;
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
        _session = [NSURLSession sessionWithConfiguration:sessionConfiguration()];
        _pending = [NSMutableDictionary dictionary];
        _downloads = [NSMutableDictionary dictionary];
        _failures = [NSMutableDictionary dictionary];
        _decodeQueue = dispatch_queue_create("plexatv.decode", DISPATCH_QUEUE_SERIAL);
        _diskDir = [PXDataDir() stringByAppendingPathComponent:@"img"];
        [[NSFileManager defaultManager] createDirectoryAtPath:_diskDir withIntermediateDirectories:YES attributes:nil error:NULL];
        // Memory warnings: drop decoded bitmaps (they are cheap to re-decode from disk).
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidReceiveMemoryWarningNotification object:nil
                                                           queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) {
            PXLog(@"images: memory warning, flushing cache");
            [self.memory removeAllObjects];
            [self.failures removeAllObjects];
        }];
    }
    return self;
}

- (void)setTrustDelegate:(id<NSURLSessionDelegate>)delegate {
    NSURLSession *old = self.session;
    self.session = [NSURLSession sessionWithConfiguration:sessionConfiguration() delegate:delegate delegateQueue:nil];
    [old finishTasksAndInvalidate];
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
            if (img) {
                utimes(path.fileSystemRepresentation, NULL);   // recently used: trimmed last
                dispatch_async(dispatch_get_main_queue(), ^{ [self finish:key image:img]; CGImageRelease(img); });
                return;
            }
            // Truncated or not an image (cache written by an older version).
            PXLog(@"images: unreadable cache file, fetching it again");
            [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [self download:url fileKey:fileKey done:^(NSData *data) {
                if (!data) { [self finish:key image:NULL]; return; }
                dispatch_async(self.decodeQueue, ^{
                    CGImageRef img = decodeImage(data, size, radius, fade);
                    // Only what decodes goes to disk; the serial queue makes
                    // the first successful variant the only writer.
                    if (img && ![[NSFileManager defaultManager] fileExistsAtPath:path])
                        [data writeToFile:path options:NSDataWritingAtomic error:NULL];
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (!img) {
                            PXLog(@"images: undecodable response (%lu bytes)", (unsigned long)data.length);
                            self.failures[fileKey] = [NSDate date];
                        }
                        [self finish:key image:img];
                        CGImageRelease(img);
                    });
                });
            }];
        });
    });
}

// Main queue. One download per file whatever the number of variants (radius,
// fades) waiting for it; a failed file is not asked again for kRetryDelay.
- (void)download:(NSURL *)url fileKey:(NSString *)fileKey done:(void (^)(NSData *data))done {
    NSDate *failed = self.failures[fileKey];
    if (failed && -[failed timeIntervalSinceNow] < kRetryDelay) { done(nil); return; }
    NSMutableArray *waiting = self.downloads[fileKey];
    if (waiting) { [waiting addObject:[done copy]]; return; }
    self.downloads[fileKey] = [NSMutableArray arrayWithObject:[done copy]];
    [[self.session dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        NSHTTPURLResponse *http = [resp isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)resp : nil;
        NSInteger code = http.statusCode;
        // Body shorter than announced (without content encoding, where sizes differ).
        BOOL truncated = !http.allHeaderFields[@"Content-Encoding"] && resp.expectedContentLength > 0
                         && (long long)data.length < resp.expectedContentLength;
        BOOL ok = !err && code == 200 && data.length && !truncated;
        if (!ok) PXLog(@"images: %@ -> HTTP %ld %@%@", url.host, (long)code, err.localizedDescription ?: @"", truncated ? @"truncated" : @"");
        dispatch_async(dispatch_get_main_queue(), ^{
            if (ok) [self.failures removeObjectForKey:fileKey];
            else self.failures[fileKey] = [NSDate date];
            NSArray *blocks = self.downloads[fileKey];
            [self.downloads removeObjectForKey:fileKey];
            for (void (^b)(NSData *) in blocks) b(ok ? data : nil);
        });
    }] resume];
}

// Least recently used first: reads touch the file date. Once per launch.
- (void)trimDiskCache {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{ [self trimNow]; });
    });
}

- (void)trimNow {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *keys = @[ NSURLContentModificationDateKey, NSURLFileSizeKey ];
    NSArray *files = [fm contentsOfDirectoryAtURL:[NSURL fileURLWithPath:self.diskDir] includingPropertiesForKeys:keys options:0 error:NULL];
    NSMutableArray *entries = [NSMutableArray arrayWithCapacity:files.count];
    unsigned long long total = 0;
    for (NSURL *f in files) {
        NSDictionary *v = [f resourceValuesForKeys:keys error:NULL];
        unsigned long long size = [v[NSURLFileSizeKey] unsignedLongLongValue];
        total += size;
        [entries addObject:@{ @"url": f, @"size": @(size), @"date": v[NSURLContentModificationDateKey] ?: [NSDate distantPast] }];
    }
    if (total <= kDiskLimit) return;
    [entries sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) { return [a[@"date"] compare:b[@"date"]]; }];
    for (NSDictionary *e in entries) {
        if (total <= kDiskLimit * 0.8) break;
        total -= [e[@"size"] unsignedLongLongValue];
        [fm removeItemAtURL:e[@"url"] error:NULL];
    }
    PXLog(@"images: disk cache trimmed to %llu MB", total / 1024 / 1024);
}

@end
