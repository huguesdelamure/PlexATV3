// ATVKit: shared foundation of PlexATV3 and of other appliances (launcher).
//
// Several appliance bundles run in the same AppleTV process and Objective-C
// class names are process-global. A product embedding the kit next to
// PlexATV3 must give the kit classes another prefix: build with
// -DKIT_PREFIX_LK to rename them (PXScreen -> LKScreen, ...). PlexATV3 itself
// uses the default PX names. C functions need no renaming (two-level
// namespace binds them inside each bundle).

#ifndef PXKIT_H
#define PXKIT_H

#ifdef KIT_PREFIX_LK
#define PXKitMarker      LKKitMarker
#define PXScreen         LKScreen
#define PXHostTemplate   LKHostTemplate
#define PXImageCache     LKImageCache
#define PXListRow        LKListRow
#define PXListLayer      LKListLayer
#define PXOverlay        LKOverlay
#define PXButton         LKButton
#define PXButtonRow      LKButtonRow
#define PXAmbientLayer   LKAmbientLayer
#define PXKIT_HOST_CLASS "LKHostController"
#else
#define PXKIT_HOST_CLASS "PXHostController"
#endif

#ifdef __OBJC__
#import <Foundation/Foundation.h>
// Bundle that embeds this copy of the kit (fonts, Info.plist, data dir name).
NSBundle *PXKitBundle(void);
#endif

#endif
