#import "PXDebug.h"
#import "PXBackRow.h"
#import "PXLog.h"
#import <QuartzCore/QuartzCore.h>
#import <mach/mach.h>
#import <dlfcn.h>
#import <pthread.h>
#import <mach-o/dyld.h>

void PXRuntimeDump(BOOL force);

static NSMutableDictionary *commands(void) {
    static NSMutableDictionary *d;
    if (!d) d = [NSMutableDictionary dictionary];
    return d;
}

void PXDebugRegister(NSString *name, PXDebugCommand block) {
    commands()[name] = [block copy];
}

static int actionForName(NSString *name) {
    NSDictionary *map = @{ @"menu": @(PXRemoteMenu), @"menuhold": @(PXRemoteMenuHold),
                           @"up": @(PXRemoteUp), @"down": @(PXRemoteDown),
                           @"select": @(PXRemoteSelect), @"left": @(PXRemoteLeft),
                           @"right": @(PXRemoteRight), @"play": @(PXRemotePlayPause) };
    NSNumber *n = map[name.lowercaseString];
    return n ? n.intValue : name.intValue;
}

static void postKey(int action) {
    id app = [PXCls("BRApplication") sharedApplication];
    [app postEvent:[PXCls("BREvent") eventWithAction:action value:1]];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        [app postEvent:[PXCls("BREvent") eventWithAction:action value:0]];
    });
}

// UI frame meter (CADisplayLink): frames/s, frames slower than 25 ms and the
// worst frame over each 2 s window, measured on the device itself.
@interface PXFrameMeterTarget : NSObject
@property (nonatomic) CFTimeInterval last, windowStart, worst;
@property (nonatomic) NSInteger frames, slow;
@end
@implementation PXFrameMeterTarget
- (void)tick:(CADisplayLink *)link {
    CFTimeInterval t = link.timestamp;
    if (self.last > 0) {
        CFTimeInterval d = t - self.last;
        if (d > 0.025) self.slow++;
        if (d > self.worst) self.worst = d;
    } else self.windowStart = t;
    self.last = t;
    self.frames++;
    if (t - self.windowStart >= 2.0) {
        PXLog(@"frames: %.1f fps, %ld slow (>25 ms), worst %.0f ms", self.frames / (t - self.windowStart), (long)self.slow, self.worst * 1000);
        self.frames = 0; self.slow = 0; self.worst = 0; self.windowStart = t;
    }
}
@end


// Main thread stall sampler: a background thread watches a heartbeat that the
// main queue updates every 20 ms; when it is late by more than 120 ms, the
// main thread is suspended for a few microseconds and its stack walked
// (armv7 frame pointer chain, r7). Frames are logged as image+offset, to be
// symbolised on the Mac with atos. Several samples per stall = a profile.
static mach_port_t gMainThread;
static volatile double gHeartbeat;
static volatile BOOL gStallWatch;
static volatile double gStallThreshold = 0.12;   // seconds
static uintptr_t gStackTop, gStackBottom;   // main thread stack bounds

static double nowSec(void) { return CACurrentMediaTime(); }

static int sampleMainStack(uintptr_t *out, int max) {
    if (thread_suspend(gMainThread) != KERN_SUCCESS) return 0;
    int n = 0;
#if defined(__arm__)
    arm_thread_state_t st;
    mach_msg_type_number_t count = ARM_THREAD_STATE_COUNT;
    if (thread_get_state(gMainThread, ARM_THREAD_STATE, (thread_state_t)&st, &count) == KERN_SUCCESS) {
        out[n++] = st.__pc;
        out[n++] = st.__lr;
        uintptr_t fp = st.__r[7], sp = st.__sp;
        while (n < max && fp && !(fp & 3) && fp >= sp && fp >= gStackBottom && fp + 8 <= gStackTop) {
            uintptr_t next = ((uintptr_t *)fp)[0], ret = ((uintptr_t *)fp)[1];
            if (!ret) break;
            out[n++] = ret;
            if (next <= fp) break;
            fp = next;
        }
    }
#endif
    thread_resume(gMainThread);
    return n;
}

static void *stallWatchThread(void *arg) {
    pthread_setname_np("px.stallwatch");
    int samplesThisStall = 0;
    while (gStallWatch) {
        usleep(gStallThreshold < 0.08 ? 10 * 1000 : 40 * 1000);
        double late = nowSec() - gHeartbeat;
        if (late < gStallThreshold) { samplesThisStall = 0; continue; }
        if (++samplesThisStall > 40) continue;
        uintptr_t frames[40];
        int n = sampleMainStack(frames, 40);
        NSMutableString *line = [NSMutableString stringWithFormat:@"stall: +%.0f ms", late * 1000];
        for (int i = 0; i < n; i++) {
            Dl_info info;
            if (dladdr((void *)frames[i], &info) && info.dli_fname) {
                const char *base = strrchr(info.dli_fname, '/');
                [line appendFormat:@" | %s+0x%lx", base ? base + 1 : info.dli_fname, (unsigned long)(frames[i] - (uintptr_t)info.dli_fbase)];
                if (info.dli_sname) [line appendFormat:@"(%s)", info.dli_sname];
            } else [line appendFormat:@" | 0x%lx", (unsigned long)frames[i]];
        }
        PXLog(@"%@", line);
    }
    return NULL;
}

static void setStallWatch(BOOL on) {
    static dispatch_source_t beat;
    if (on == gStallWatch) return;
    gStallWatch = on;
    if (!on) { if (beat) dispatch_source_cancel(beat); beat = nil; return; }
    gHeartbeat = nowSec();
    beat = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(beat, DISPATCH_TIME_NOW, 20 * NSEC_PER_MSEC, 5 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(beat, ^{ gHeartbeat = nowSec(); });
    dispatch_resume(beat);
    pthread_t t;
    pthread_create(&t, NULL, stallWatchThread, NULL);
    pthread_detach(t);
    // Image bases, to symbolise offsets with atos -l.
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *name = _dyld_get_image_name(i);
        if (strstr(name, ".frappliance") || strstr(name, "AppleTV.app/AppleTV"))
            PXLog(@"stall: image %s base %p", name, _dyld_get_image_header(i));
    }
}

static void registerBuiltins(void) {
    static CADisplayLink *meter;
    static PXFrameMeterTarget *meterTarget;
    PXDebugRegister(@"fpsmeter", ^(NSArray *a) {
        BOOL on = !a.count || [a[0] isEqual:@"on"];
        [meter invalidate];
        meter = nil;
        if (!on) return;
        meterTarget = [PXFrameMeterTarget new];
        meter = [CADisplayLink displayLinkWithTarget:meterTarget selector:@selector(tick:)];
        [meter addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    });
    // stallwatch on|off: log main thread stacks during stalls > 120 ms.
    // stallwatch on [threshold ms] | off
    PXDebugRegister(@"stallwatch", ^(NSArray *a) {
        if (a.count > 1) gStallThreshold = MAX(30, [a[1] doubleValue]) / 1000.0;
        setStallWatch(!a.count || [a[0] isEqual:@"on"]);
    });
    PXDebugRegister(@"key", ^(NSArray *a) { if (a.count) postKey(actionForName(a[0])); });
    // Like the real IR remote: a single press event, no release.
    PXDebugRegister(@"tap", ^(NSArray *a) {
        if (a.count) [[PXCls("BRApplication") sharedApplication] postEvent:[PXCls("BREvent") eventWithAction:actionForName(a[0]) value:1]];
    });
    // burst <key> <count> <interval ms>: on-device key repeat (SSH adds ~0.5 s per command).
    PXDebugRegister(@"burst", ^(NSArray *a) {
        if (a.count < 1) return;
        int action = actionForName(a[0]);
        NSInteger count = a.count > 1 ? [a[1] integerValue] : 8;
        double interval = (a.count > 2 ? [a[2] doubleValue] : 200) / 1000.0;
        for (NSInteger i = 0; i < count; i++)
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * interval * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [[PXCls("BRApplication") sharedApplication] postEvent:[PXCls("BREvent") eventWithAction:action value:1]];
            });
    });
    PXDebugRegister(@"actions", ^(NSArray *a) {
        for (int i = 0; i < 64; i++) PXLog(@"action %d = %@", i, [[PXCls("BREvent") eventWithAction:i value:1] _actionDescription]);
    });
    PXDebugRegister(@"stack", ^(NSArray *a) {
        for (id c in [[[PXCls("BRApplicationStackManager") singleton] stack] controllers]) PXLog(@"stack: %@", NSStringFromClass([c class]));
    });
    PXDebugRegister(@"appliances", ^(NSArray *a) {
        id mgr = [PXCls("BRApplianceManager") singleton];
        for (id info in [mgr applianceInfoList])
            PXLog(@"appliance key=%@ name=%@ principal=%@", [info valueForKey:@"key"], [info valueForKey:@"name"], [info valueForKey:@"principalClassName"]);
    });
    PXDebugRegister(@"dump", ^(NSArray *a) { dispatch_async(dispatch_get_global_queue(0, 0), ^{ PXRuntimeDump(YES); }); });
}

static void runCommand(NSString *line) {
    NSMutableArray *parts = [[line componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] mutableCopy];
    [parts removeObject:@""];
    if (!parts.count) return;
    NSString *cmd = parts[0];
    [parts removeObjectAtIndex:0];
    PXLog(@"debug cmd: %@", line);
    PXDebugCommand block = commands()[cmd];
    if (!block) { PXLog(@"debug: unknown command %@", cmd); return; }
    @try { block(parts); } @catch (NSException *e) { PXLog(@"debug: %@ failed: %@", cmd, e.reason); }
}

void PXDebugStart(void) {
    gMainThread = mach_thread_self();   // PXDebugStart runs on the main thread
    pthread_t me = pthread_self();
    gStackTop = (uintptr_t)pthread_get_stackaddr_np(me);          // stack grows down from here
    gStackBottom = gStackTop - pthread_get_stacksize_np(me);
    registerBuiltins();
    NSString *path = [PXDataDir() stringByAppendingPathComponent:@"cmd"];
    static dispatch_source_t timer;
    timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, 150 * NSEC_PER_MSEC, 50 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(timer, ^{
        if (access(path.fileSystemRepresentation, F_OK) != 0) return;
        // Atomic take-over: a writer appending after this point creates a new file.
        NSString *taken = [path stringByAppendingString:@".run"];
        if (rename(path.fileSystemRepresentation, taken.fileSystemRepresentation) != 0) return;
        NSString *content = [NSString stringWithContentsOfFile:taken encoding:NSUTF8StringEncoding error:NULL];
        unlink(taken.fileSystemRepresentation);
        for (NSString *l in [content componentsSeparatedByString:@"\n"]) runCommand(l);
    });
    dispatch_resume(timer);
}
