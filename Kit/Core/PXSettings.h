#import <Foundation/Foundation.h>

// Persistent settings in <PXDataDir>/settings.plist (owned by mobile).
// Keys: clientId, authToken, serverId, serverName, serverURI, serverToken.
id PXSettingGet(NSString *key);
void PXSettingSet(NSString *key, id value);
NSString *PXClientId(void);
