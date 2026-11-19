#import "PXLog.h"
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <stdio.h>

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

static const long kLogMaxSize = 1024 * 1024;   // then one previous file, <name>.1

// Private to mobile: the log names servers and addresses.
static FILE *openLog(NSString *path) {
    int fd = open(path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND, 0600);
    if (fd < 0) return NULL;
    fchmod(fd, 0600);
    FILE *f = fdopen(fd, "a");
    if (!f) close(fd);
    return f;
}

void PXLog(NSString *fmt, ...) {
    static dispatch_queue_t q;
    static FILE *f;
    static NSString *path;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        q = dispatch_queue_create("plexatv.log", DISPATCH_QUEUE_SERIAL);
        path = [PXDataDir() stringByAppendingPathComponent:@"plexatv.log"];
        f = openLog(path);
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
        if (ftell(f) > kLogMaxSize) {
            fclose(f);
            rename(path.fileSystemRepresentation, [path stringByAppendingString:@".1"].fileSystemRepresentation);
            f = openLog(path);
        }
    });
}
