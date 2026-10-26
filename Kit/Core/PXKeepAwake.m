#import "PXKeepAwake.h"
#import "PXBackRow.h"
#import "PXLog.h"
#import <dlfcn.h>

// IOKit power assertions, resolved at run time (no IOKit headers in the iOS SDK).
typedef uint32_t PXAssertionID;
typedef int (*PXAssertCreate)(CFStringRef type, uint32_t level, CFStringRef name, PXAssertionID *outID);
typedef int (*PXAssertRelease)(PXAssertionID aid);

static PXAssertionID gAssertion;
static BOOL gHeld;
static CFAbsoluteTime gLastHoldOff;

static void *iokit(const char *sym) {
    static void *h;
    if (!h) h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
    return h ? dlsym(h, sym) : NULL;
}

void PXKeepAwake(BOOL video) {
    if (!gHeld) {
        PXAssertCreate create = (PXAssertCreate)iokit("IOPMAssertionCreateWithName");
        // kIOPMAssertionTypeNoIdleSleep, kIOPMAssertionLevelOn (255)
        if (create && create(CFSTR("NoIdleSleepAssertion"), 255, CFSTR("PlexATV3 playback"), &gAssertion) == 0) gHeld = YES;
        PXLog(@"awake: idle sleep assertion %@", gHeld ? @"held" : @"failed");
    }
    if (!video) return;
    // The screensaver timer is reset like a key press, every 20 s at most.
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - gLastHoldOff < 20) return;
    gLastHoldOff = now;
    [[NSNotificationCenter defaultCenter] postNotificationName:@"ATVScreenSaverHoldOff" object:nil];
    id mgr = [PXCls("ATVScreenSaverManager") singleton];
    if ([mgr respondsToSelector:@selector(_updateActivity:)]) [mgr performSelector:@selector(_updateActivity:) withObject:nil];
}

void PXAllowSleep(void) {
    if (!gHeld) return;
    PXAssertRelease release = (PXAssertRelease)iokit("IOPMAssertionRelease");
    if (release) release(gAssertion);
    gHeld = NO;
    gLastHoldOff = 0;
    PXLog(@"awake: idle sleep allowed");
}
