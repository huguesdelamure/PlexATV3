// Development channel driven over SSH (DEBUG builds only): write command
// lines into <PXDataDir>/cmd, they run on the main thread.
//
// Built-in commands:
//   key <up|down|left|right|select|menu|menuhold|play|N>   inject a remote press
//   actions        log BREvent action codes
//   stack          log the BackRow controller stack
//   appliances     log the installed appliances
//   dump           dump the AppleTV ObjC runtime to <PXDataDir>/dump
// Products add their own with PXDebugRegister().

#import <Foundation/Foundation.h>

typedef void (^PXDebugCommand)(NSArray *args);
void PXDebugRegister(NSString *name, PXDebugCommand block);
void PXDebugStart(void);
