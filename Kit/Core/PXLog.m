#import "PXLog.h"

@interface PXKitMarker : NSObject
@end
@implementation PXKitMarker
@end

NSBundle *PXKitBundle(void) {
    return [NSBundle bundleForClass:[PXKitMarker class]];
}

// One data directory per host bundle: /var/mobile/Library/Caches/<executable>.
NSString *PXDataDir(void) {
    static NSString *dir;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *name = [PXKitBundle() objectForInfoDictionaryKey:@"CFBundleExecutable"] ?: @"ATVKit";
        dir = [@"/var/mobile/Library/Caches" stringByAppendingPathComponent:name];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
    });
    return dir;
}

void PXLog(NSString *fmt, ...) {
    static dispatch_queue_t q;
    static FILE *f;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        q = dispatch_queue_create("plexatv.log", DISPATCH_QUEUE_SERIAL);
        NSString *path = [PXDataDir() stringByAppendingPathComponent:@"plexatv.log"];
        f = fopen(path.fileSystemRepresentation, "a");
    });
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSDate *now = [NSDate date];
    dispatch_async(q, ^{
        if (!f) return;
        static NSDateFormatter *df;
        if (!df) { df = [NSDateFormatter new]; df.dateFormat = @"HH:mm:ss.SSS"; }
        fprintf(f, "%s %s\n", [[df stringFromDate:now] UTF8String], msg.UTF8String);
        fflush(f);
    });
}
