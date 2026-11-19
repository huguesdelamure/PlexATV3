#import "PXSettings.h"
#import "PXLog.h"
#import <UIKit/UIKit.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <stdio.h>

// Writes are coalesced (PXSettingSet runs on every volume step): the file is
// written at most kWriteDelay after a change, the values in memory are
// current at once. Not declared in PXSettings.h: writes the pending changes now.
void PXSettingsFlush(void);

static const NSTimeInterval kWriteDelay = 1;
static BOOL gDirty;

static NSString *settingsPath(void) {
    return [PXDataDir() stringByAppendingPathComponent:@"settings.plist"];
}

static NSMutableDictionary *settings(void) {
    static NSMutableDictionary *dict;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dict = [NSMutableDictionary dictionaryWithContentsOfFile:settingsPath()] ?: [NSMutableDictionary dictionary];
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillTerminateNotification object:nil
                                                           queue:nil usingBlock:^(NSNotification *n) { PXSettingsFlush(); }];
    });
    return dict;
}

id PXSettingGet(NSString *key) {
    NSMutableDictionary *d = settings();
    @synchronized (d) { return d[key]; }
}

// The token is a credential: the file is created private to mobile (0600)
// before any byte is written, then renamed over the old one.
static BOOL writeSettings(NSData *data) {
    NSString *path = settingsPath();
    NSString *tmp = [path stringByAppendingString:@".tmp"];
    int fd = open(tmp.fileSystemRepresentation, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (fd < 0) return NO;
    fchmod(fd, 0600);   // an older temp file may have kept other permissions
    BOOL ok = write(fd, data.bytes, data.length) == (ssize_t)data.length;
    ok = (close(fd) == 0) && ok;
    if (ok) ok = rename(tmp.fileSystemRepresentation, path.fileSystemRepresentation) == 0;
    if (!ok) { int e = errno; unlink(tmp.fileSystemRepresentation); errno = e; }
    return ok;
}

void PXSettingsFlush(void) {
    NSMutableDictionary *d = settings();
    NSData *data = nil;
    NSError *err = nil;
    @synchronized (d) {
        if (!gDirty) return;
        gDirty = NO;
        data = [NSPropertyListSerialization dataWithPropertyList:d format:NSPropertyListXMLFormat_v1_0 options:0 error:&err];
    }
    if (!data) { PXLog(@"settings: not saved, %@", err.localizedDescription); return; }
    if (!writeSettings(data)) PXLog(@"settings: write failed (errno %d)", errno);
}

void PXSettingSet(NSString *key, id value) {
    NSMutableDictionary *d = settings();
    BOOL schedule;
    @synchronized (d) {
        if (value) d[key] = value;
        else [d removeObjectForKey:key];
        schedule = !gDirty;
        gDirty = YES;
    }
    if (schedule)
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kWriteDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ PXSettingsFlush(); });
}

NSString *PXClientId(void) {
    NSString *cid = PXSettingGet(@"clientId");
    if (!cid) {
        cid = [[NSUUID UUID] UUIDString].lowercaseString;
        PXSettingSet(@"clientId", cid);
    }
    return cid;
}
