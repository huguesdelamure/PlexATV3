#import <Foundation/Foundation.h>

// Appends to <PXDataDir>/plexatv.log (NSLog/ASL is not
// readable easily over SSH on this device).
void PXLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
NSString *PXDataDir(void);   // /var/mobile/Library/Caches/<host bundle executable>
