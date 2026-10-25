#import "PXBif.h"
#import "PXServer.h"
#import "PXPlex.h"
#import "PXSettings.h"
#import "PXLog.h"
#import <ImageIO/ImageIO.h>
#import <libkern/OSByteOrder.h>

// BIF layout: 8-byte magic, version, image count, interval (ms, 0 = 1000),
// padding to 64, then (timestamp, offset) uint32 pairs, last offset = EOF.
static const uint8_t kMagic[8] = { 0x89, 0x42, 0x49, 0x46, 0x0d, 0x0a, 0x1a, 0x0a };

@implementation PXBif {
    NSData *_data;
    uint32_t _count, _interval;
    NSInteger _lastIndex;
    CGImageRef _lastImage;
    NSString *_path;
}

+ (instancetype)bifForPartID:(NSString *)partID server:(PXServer *)server {
    if (!partID.length || !server) return nil;
    static NSMutableDictionary *cache;
    if (!cache) cache = [NSMutableDictionary dictionary];
    NSString *key = [NSString stringWithFormat:@"%@-%@", server.identifier, partID];   // part IDs are per server
    PXBif *b = cache[key];
    if (!b) {
        b = [[PXBif alloc] initWithPartID:partID server:server key:key];
        [cache removeAllObjects];   // keep one at a time
        cache[key] = b;
    }
    return b;
}

- (instancetype)initWithPartID:(NSString *)partID server:(PXServer *)server key:(NSString *)key {
    if ((self = [super init])) {
        _lastIndex = -1;
        NSString *dir = [PXDataDir() stringByAppendingPathComponent:@"bif"];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
        _path = [dir stringByAppendingPathComponent:[key stringByAppendingString:@".bif"]];
        if (![self open]) [self download:partID server:server dir:dir];
    }
    return self;
}

- (BOOL)open {
    NSData *d = [NSData dataWithContentsOfFile:_path options:NSDataReadingMappedAlways error:NULL];
    if (d.length < 64 || memcmp(d.bytes, kMagic, 8) != 0) return NO;
    const uint8_t *p = d.bytes;
    _count = OSReadLittleInt32(p, 12);
    _interval = OSReadLittleInt32(p, 16) ?: 1000;
    if (d.length < 64 + (_count + 1) * 8) return NO;
    _data = d;
    _ready = YES;
    PXLog(@"bif: %u thumbnails every %u ms", _count, _interval);
    return YES;
}

- (void)download:(NSString *)partID server:(PXServer *)server dir:(NSString *)dir {
    // Only the most recent BIF is kept on disk.
    for (NSString *f in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:NULL])
        [[NSFileManager defaultManager] removeItemAtPath:[dir stringByAppendingPathComponent:f] error:NULL];
    NSString *base = server.uri, *token = server.token;
    if (!base) return;
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@/library/parts/%@/indexes/sd?X-Plex-Token=%@", base, partID, PXEncode(token)]];
    __weak PXBif *weak = self;
    NSString *path = _path;
    [[[NSURLSession sharedSession] downloadTaskWithURL:url completionHandler:^(NSURL *location, NSURLResponse *resp, NSError *err) {
        if (err || [(NSHTTPURLResponse *)resp statusCode] != 200 || !location) {
            PXLog(@"bif: download failed %ld %@", (long)[(NSHTTPURLResponse *)resp statusCode], err.localizedDescription);
            return;
        }
        [[NSFileManager defaultManager] moveItemAtURL:location toURL:[NSURL fileURLWithPath:path] error:NULL];
        dispatch_async(dispatch_get_main_queue(), ^{ [weak open]; });
    }] resume];
}

- (CGImageRef)imageAt:(double)seconds {
    if (!_ready || !_count) return NULL;
    NSInteger i = (NSInteger)(seconds * 1000.0 / _interval);
    i = MAX(0, MIN(i, (NSInteger)_count - 1));
    if (i == _lastIndex) return _lastImage;
    const uint8_t *p = _data.bytes;
    uint32_t off = OSReadLittleInt32(p, 64 + i * 8 + 4), next = OSReadLittleInt32(p, 64 + (i + 1) * 8 + 4);
    if (off >= next || next > _data.length) return _lastImage;
    NSData *jpg = [_data subdataWithRange:NSMakeRange(off, next - off)];
    CGImageSourceRef src = CGImageSourceCreateWithData((__bridge CFDataRef)jpg, NULL);
    CGImageRef img = src ? CGImageSourceCreateImageAtIndex(src, 0, NULL) : NULL;
    if (src) CFRelease(src);
    if (!img) return _lastImage;
    if (_lastImage) CGImageRelease(_lastImage);
    _lastImage = img;
    _lastIndex = i;
    return img;
}

- (void)dealloc {
    if (_lastImage) CGImageRelease(_lastImage);
}

@end
