// Design system: fonts (Inter, bundled), colors, animation helpers, icons.

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import "PXLocalize.h"

// ---- Fonts --------------------------------------------------------------
// Registers the bundled Inter fonts (call once at load).
void PXRegisterFonts(void);

typedef NS_ENUM(NSInteger, PXWeight) { PXRegular, PXMedium, PXSemibold, PXBold, PXHeavy };
UIFont *PXFontW(CGFloat size, PXWeight weight);
// Shorthands.
UIFont *PXFont(CGFloat size);       // regular
UIFont *PXFontMedium(CGFloat size);
UIFont *PXFontSemi(CGFloat size);
UIFont *PXFontBold(CGFloat size);
UIFont *PXFontHeavy(CGFloat size);
UIFont *PXFontLight(CGFloat size);  // regular (no light weight bundled)

// ---- Colors -------------------------------------------------------------
CGColorRef PXColorBackground(void);   // near-black, slightly blue
CGColorRef PXColorAccent(void);       // Plex amber
CGColorRef PXColorText(void);         // white
CGColorRef PXColorTextDim(void);      // 62 % white
CGColorRef PXColorTextFaint(void);    // 40 % white
CGColorRef PXColorPanel(void);        // translucent white 14 %
CGColorRef PXColorPanelStrong(void);  // translucent white 24 %
CGColorRef PXColorWhite(CGFloat alpha);
CGColorRef PXColorBlack(CGFloat alpha);
CGColorRef PXColorHex(NSString *hex, CGFloat alpha);   // "1b3461"

// ---- Text ---------------------------------------------------------------
CATextLayer *PXText(UIFont *font, CGColorRef color);
void PXSetText(CATextLayer *layer, NSString *text);
CGFloat PXTextHeight(NSString *text, UIFont *font, CGFloat width);
CGFloat PXTextWidth(NSString *text, UIFont *font);
// Largest font (maxSize down to minSize, step 4) whose text fits in maxLines.
UIFont *PXFitFont(NSString *text, PXWeight weight, CGFloat maxSize, CGFloat minSize, CGFloat width, NSInteger maxLines);
// Draws text into `layer` off the main thread (big texts cost 100+ ms of
// main thread on the A5 when drawn by CATextLayer). The layer keeps its
// frame origin; its height is set to the drawn text height (<= maxLines).
// fitMinSize > 0: the font shrinks (down to fitMinSize) to fit maxLines.
void PXDrawTextAsync(CALayer *layer, NSString *text, UIFont *font, CGColorRef color,
                     CGFloat width, NSInteger maxLines, CGFloat fitMinSize);

// Text layer drawn off the main thread (see PXDrawTextAsync), at `frame`
// (its height becomes the drawn text height). centered: the layer is narrowed
// to the text and centred in `frame` (single line).
CALayer *PXAsyncLabel(NSString *text, UIFont *font, CGColorRef color, CGRect frame, NSInteger maxLines, BOOL centered);

// Outlined pill ("4K", "HDR") or plain label rendered once and cached as an
// image: CATextLayers redrawn on every focus change were the main cost of the
// home hero. Returns a layer at origin, height 38.
CALayer *PXPillLayer(NSString *text, CGPoint origin);
CALayer *PXCachedLabel(NSString *text, UIFont *font, UIColor *color, CGPoint origin);

// Text layer sized to its content (single line), positioned at origin.
CATextLayer *PXLabel(NSString *text, UIFont *font, CGColorRef color, CGPoint origin);

// ---- Animation ----------------------------------------------------------
void PXNoAnim(void (^block)(void));
void PXAnim(CFTimeInterval duration, void (^block)(void));
// Spring-like scale (overshoot) on a layer, iOS 8 has no CASpringAnimation.
void PXSpringScale(CALayer *layer, CGFloat to);
// One-shot diagonal light sweep over a rounded rect (focus gloss).
void PXGlossSweep(CALayer *layer, CGFloat cornerRadius);
// Crossfade the next contents change of a layer.
void PXFadeContents(CALayer *layer, CFTimeInterval duration);

// ---- Shapes / icons -----------------------------------------------------
typedef NS_ENUM(NSInteger, PXIcon) {
    PXIconPlay, PXIconPause, PXIconRestart, PXIconAudio, PXIconSubtitles, PXIconCheck,
    PXIconGear, PXIconSearch, PXIconChapters, PXIconInfo, PXIconNext, PXIconStar,
};
CAShapeLayer *PXIconLayer(PXIcon icon, CGFloat size, CGColorRef color);

// Rotating arc spinner (modern loading indicator), centred at origin of its frame.
CALayer *PXSpinner(CGFloat size);

// ---- Time ---------------------------------------------------------------
NSString *PXClock(double seconds);          // 1:02:03 or 02:03
NSString *PXDurationText(double seconds);   // "1 h 52" / "47 min"
NSString *PXWallClock(NSDate *date);        // "21:47"
