#import "PXSettings.h"
#import "PXLog.h"
#import <sys/stat.h>

static NSString *settingsPath(void) {
    return [PXDataDir() stringByAppendingPathComponent:@"settings.plist"];
}

static NSMutableDictionary *settings(void) {
    static NSMutableDictionary *dict;
    if (!dict) {
        dict = [NSMutableDictionary dictionaryWithContentsOfFile:settingsPath()] ?: [NSMutableDictionary dictionary];
    }
    return dict;
}

id PXSettingGet(NSString *key) {
    return settings()[key];
}

void PXSettingSet(NSString *key, id value) {
    if (value) settings()[key] = value;
    else [settings() removeObjectForKey:key];
    [settings() writeToFile:settingsPath() atomically:YES];
    // The token is a credential: keep the file private to mobile.
    chmod(settingsPath().fileSystemRepresentation, 0600);
}

NSString *PXClientId(void) {
    NSString *cid = PXSettingGet(@"clientId");
    if (!cid) {
        cid = [[NSUUID UUID] UUIDString].lowercaseString;
        PXSettingSet(@"clientId", cid);
    }
    return cid;
}
