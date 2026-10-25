#import "PXScreen.h"
#import "PXBackRow.h"
#import "PXLog.h"

#define HOST PXKIT_HOST_CLASS

static PXKey keyForAction(int action) {
    switch (action) {
        case 1:  return PXKeyMenu;
        case 2:  return PXKeyMenuHold;
        case 3:  return PXKeyUp;
        case 4:  return PXKeyDown;
        case 5:  return PXKeySelect;        // play/pause-select (center button)
        case 6:  return PXKeyLeft;
        case 7:  return PXKeyRight;
        case 8:  return PXKeyRewind;
        case 9:  return PXKeyFastForward;
        case 10: return PXKeyPlayPause;
        case 11: return PXKeyPlayPauseHold;
        case 12: return PXKeySelect;
        case 22: return PXKeySelectHold;    // measured: center held ~1 s -> 22, release -> 23
        case 15: case 16: return PXKeyPlayPause;  // discrete pause / play
        case 18: return PXKeyFastForward;
        case 19: return PXKeyRewind;
        default: return PXKeyNone;
    }
}

#pragma mark - BackRow host controller (runtime subclass of BRController)

@interface PXHostTemplate : NSObject
@end

@implementation PXHostTemplate

- (PXScreen *)px_screen { return PXGet(self, "screen"); }

- (void)px_attach {
    PXScreen *s = [self px_screen];
    UIView *v = (UIView *)self;
    v.backgroundColor = [UIColor blackColor];
    [v.layer addSublayer:s.layer];
    [self px_layout];
}

- (void)px_layout {
    UIView *v = (UIView *)self;
    CGRect b = v.bounds;
    if (CGRectIsEmpty(b)) return;
    PXScreen *s = [self px_screen];
    // Scale the 1920x1080 design space to the actual interface size (720p TVs).
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    s.layer.bounds = CGRectMake(0, 0, s.size.width, s.size.height);
    s.layer.position = CGPointMake(CGRectGetMidX(b), CGRectGetMidY(b));
    CGFloat k = MIN(b.size.width / s.size.width, b.size.height / s.size.height);
    s.layer.transform = CATransform3DMakeScale(k, k, 1);
    [CATransaction commit];
}

- (void)layoutSubcontrols {
    PX_SUPER(HOST, void, self);
    [self px_layout];
}

- (char)brEventAction:(id)event {
    int action = [event remoteAction];
    int value = PXEventValue(event);
    PXKey key = keyForAction(action);
#ifdef DEBUG
    PXLog(@"remote: action=%d value=%d originator=%u t=%.3f", action, value, [event originator], [event timeStamp]);
#endif
    if (action == 23) return 1;   // end of a context-menu hold: nothing to do
    if (key == PXKeyNone) return PX_SUPER_ARGS(HOST, char, (id), self, event);
    // Releases are swallowed: acting on them would also reach the controller
    // below after a pop (double back).
    if (value != 1) return 1;
#ifdef DEBUG
    CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
#endif
    @try {
        // Never pop the root controller (e.g. a launcher home that replaced the stock menu).
        if (![[self px_screen] handleKey:key] && key == PXKeyMenu && [[[self stack] controllers] count] > 1)
            [[self stack] popController];
    } @catch (NSException *e) {
        PXLog(@"handleKey exception: %@ %@", e.name, e.reason);
    }
#ifdef DEBUG
    // Time spent in our handler, then in the Core Animation commit it caused
    // (layout, text drawing, image upload).
    CFAbsoluteTime t1 = CFAbsoluteTimeGetCurrent();
    [CATransaction flush];
    CFAbsoluteTime t2 = CFAbsoluteTimeGetCurrent();
    PXLog(@"perf: key %ld handler %.0f ms, commit %.0f ms", (long)key, (t1 - t0) * 1000, (t2 - t1) * 1000);
#endif
    return 1;
}

- (void)wasPushed   { PX_SUPER(HOST, void, self); [[self px_screen] didAppear]; }
- (void)wasExhumed  { PX_SUPER(HOST, void, self); [self px_layout]; [[self px_screen] didAppear]; }
- (void)wasBuried   { [[self px_screen] willDisappear]; PX_SUPER(HOST, void, self); }
- (void)wasPopped {
    PXScreen *s = [self px_screen];
    [s willDisappear];
    [s didPop];
    PX_SUPER(HOST, void, self);
}

@end

id PXHostControllerForScreen(PXScreen *screen) {
    Class cls = PXCreateSubclass(HOST, "BRController", [PXHostTemplate class]);
    id c = [[cls alloc] init];
    PXSet(c, "screen", screen);
    screen.host = c;
    [c px_attach];
    return c;
}

#pragma mark - PXScreen

@implementation PXScreen

- (instancetype)init {
    if ((self = [super init])) {
        _size = CGSizeMake(1920, 1080);
        _hasFocus = YES;
        _layer = [CALayer layer];
        _layer.geometryFlipped = YES;     // top-left origin for all our layout
        _layer.bounds = CGRectMake(0, 0, _size.width, _size.height);
        _layer.masksToBounds = YES;
    }
    return self;
}

- (void)push:(PXScreen *)screen {
    [[self.host stack] pushController:PXHostControllerForScreen(screen)];
}

- (void)pop {
    if ([self isOnTop]) [[self.host stack] popController];
}

- (BOOL)isOnTop {
    return self.host && [[self.host stack] peekController] == self.host;
}

- (void)setHasFocus:(BOOL)hasFocus {
    if (hasFocus == _hasFocus) return;
    _hasFocus = hasFocus;
    [self focusChanged];
}

- (void)focusChanged {}

- (void)didAppear {}
- (void)willDisappear {}
- (void)didPop {}

- (BOOL)handleKey:(PXKey)key {
    return NO;
}

@end
