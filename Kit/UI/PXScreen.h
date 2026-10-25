// Base class of every screen of the app.
//
// A screen owns a CALayer tree (top-left origin, 1920x1080 design space) and
// receives remote keys. It is hosted by a thin BackRow controller (PXHost),
// so the system controller stack gives us transitions and the Menu-back
// behaviour of the rest of the Apple TV UI.

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

typedef NS_ENUM(NSInteger, PXKey) {
    PXKeyNone = 0,
    PXKeyMenu,
    PXKeyMenuHold,
    PXKeyUp,
    PXKeyDown,
    PXKeyLeft,
    PXKeyRight,
    PXKeySelect,
    PXKeyPlayPause,
    PXKeyPlayPauseHold,
    PXKeySelectHold,      // long press on the center button (BackRow "context menu")
    PXKeyFastForward,
    PXKeyRewind,
};

@interface PXScreen : NSObject

@property (nonatomic, readonly) CALayer *layer;   // root layer, geometryFlipped
@property (nonatomic, readonly) CGSize size;      // design size (1920x1080)
@property (nonatomic, weak) id host;              // BackRow controller hosting us

// Navigation (pushes a new host controller on the BackRow stack).
- (void)push:(PXScreen *)screen;
- (void)pop;
- (BOOL)isOnTop;

// Lifecycle, to override. Always call super.
- (void)didAppear;      // pushed or uncovered
- (void)willDisappear;  // covered by another screen or popped
- (void)didPop;         // removed from the stack: release resources

// Embedding (tab containers): an embedded screen draws under the container's
// tab bar (leave ~140 px at the top) and returns NO for Up at its top edge
// and for Menu, so the container can move the focus back to the tabs.
@property (nonatomic, assign) BOOL embedded;
@property (nonatomic, assign) BOOL hasFocus;   // embedded: focus is inside this screen
- (void)focusChanged;                           // called when hasFocus changes

// Keys (presses and auto-repeats). Return YES if consumed.
// Default: Menu pops the screen.
- (BOOL)handleKey:(PXKey)key;

@end

// Creates the BackRow host controller for a screen (used by push: and by the appliance).
id PXHostControllerForScreen(PXScreen *screen);
