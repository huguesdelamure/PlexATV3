// Declarations of the BackRow (ATV Software 7.9) methods we call.
// The classes are resolved at runtime (PXCls); these are declared on NSObject
// only so the compiler knows the signatures. Reference: reference/backrow-7.9/.

#import <UIKit/UIKit.h>
#import "PXRuntime.h"

@interface NSObject (PXBackRow)
// BRApplianceCategory
- (id)categoryWithName:(id)name identifier:(id)ident preferredOrder:(float)order;
// BRApplication / BREvent
- (id)sharedApplication;
- (void)postEvent:(id)event;
- (id)eventWithAction:(int)action value:(int)value;
- (int)remoteAction;
- (unsigned int)originator;
- (double)timeStamp;
- (id)_actionDescription;
// BRController / BRControllerStack
- (id)stack;
- (void)pushController:(id)c;
- (void)popController;
- (void)swapController:(id)c;
- (void)removeController:(id)c;
- (id)peekController;
- (id)controllers;
- (void)replaceAllControllersWithController:(id)c;
- (int)count;
- (id)applianceInfoList;
- (id)controllerForApplianceKey:(id)key identifier:(id)ident args:(id)args;
- (id)applianceCategories;
- (id)applianceForInfo:(id)info;
- (id)applianceController;
- (id)controllerForIdentifier:(id)ident args:(id)args;
- (id)singleton;
- (char)brEventAction:(id)event;
- (void)wasPushed;
- (void)wasPopped;
// BRMenuController / BRListControl / BRMenuItem
- (id)list;
- (void)setDatasource:(id)ds;
- (id)datasource;
- (void)wasExhumed;
- (void)reload;
- (void)setListTitle:(id)t;
- (void)setPrimaryInfoText:(id)t;
- (void)setSecondaryInfoText:(id)t;
- (long)selectedItem;
- (void)setText:(id)t withAttributes:(id)attrs;
- (void)setRightJustifiedText:(id)t;
- (void)addAccessoryOfType:(int)type;
// BRThemeInfo
- (id)sharedTheme;
- (id)menuItemTextAttributes;
@end

// -[BREvent value] (name clashes with other -value methods, so typed call).
static inline int PXEventValue(id event) {
    return ((int (*)(id, SEL))objc_msgSend)(event, sel_registerName("value"));
}

// Uniform Menu handling for our controllers: pop on press, swallow the release.
// Otherwise the release reaches the controller below and pops it too.
// Returns YES if the event was consumed.
static inline BOOL PXHandleMenu(id controller, id event) {
    if ([event remoteAction] != 1) return NO;
    if (PXEventValue(event) == 1) [[controller stack] popController];
    return YES;
}

// BREvent remoteAction values (measured on ATV 7.9, see PXDebug "actions").
enum {
    PXRemoteMenu      = 1,
    PXRemoteMenuHold  = 2,
    PXRemoteUp        = 3,
    PXRemoteDown      = 4,
    PXRemoteSelect    = 5,
    PXRemoteLeft      = 6,
    PXRemoteRight     = 7,
    PXRemotePlayPause = 10,
};
