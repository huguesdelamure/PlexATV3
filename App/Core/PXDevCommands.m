// Plex-specific development commands for the SSH debug channel (DEBUG builds).
//   items [sectionKey | /raw/path]   log sections or items
//   play <ratingKey> [offset]        open the player on top of the stack
//   fetch <url> [METHOD]             HTTP(S) reachability test with the system TLS stack

#ifdef DEBUG
#import "PXDebug.h"
#import "PXBackRow.h"
#import "PXRouter.h"
#import "PXPlex.h"
#import "PXServer.h"
#import "PXItem.h"
#import "PXLog.h"
#import <objc/runtime.h>

void PXRegisterDevCommands(void) {
    // methods <Class> [filter]: instance + class methods of a class (and supers with "super").
    PXDebugRegister(@"methods", ^(NSArray *a) {
        if (!a.count) return;
        NSString *f = a.count > 1 ? [a[1] lowercaseString] : nil;
        for (Class c = NSClassFromString(a[0]); c && c != [NSObject class]; c = class_getSuperclass(c)) {
            for (int meta = 0; meta < 2; meta++) {
                unsigned cnt = 0;
                Method *ms = class_copyMethodList(meta ? object_getClass(c) : c, &cnt);
                NSMutableArray *names = [NSMutableArray array];
                for (unsigned k = 0; k < cnt; k++) {
                    NSString *n = NSStringFromSelector(method_getName(ms[k]));
                    if (!f || [n.lowercaseString containsString:f]) [names addObject:[NSString stringWithFormat:@"%@%@<%s>", meta ? @"+" : @"", n, method_getTypeEncoding(ms[k])]];
                }
                free(ms);
                if (names.count) PXLog(@"methods %@: %@", NSStringFromClass(c), [names componentsJoinedByString:@" "]);
            }
        }
    });
    // servers: plex.tv resources of the account (no tokens logged).
    PXDebugRegister(@"servers", ^(NSArray *a) {
        [[PXPlex shared] fetchServers:^(NSArray *servers, NSError *err) {
            PXLog(@"servers: %lu (%@)", (unsigned long)servers.count, err.localizedDescription ?: @"ok");
            for (NSDictionary *r in servers)
                PXLog(@"server: %@ id=%@ owned=%@ presence=%@ product=%@ version=%@ connections=%lu home=%@ source=%@", r[@"name"], [r[@"clientIdentifier"] substringToIndex:MIN((NSUInteger)8, [r[@"clientIdentifier"] length])], r[@"owned"], r[@"presence"],
                      r[@"product"], r[@"productVersion"], (unsigned long)[r[@"connections"] count], r[@"home"], r[@"sourceTitle"]);
        }];
    });
    PXDebugRegister(@"items", ^(NSArray *a) {
        NSString *path = a.count ? ([a[0] hasPrefix:@"/"] ? a[0] : [NSString stringWithFormat:@"/library/sections/%@/all?X-Plex-Container-Start=0&X-Plex-Container-Size=15", a[0]]) : @"/library/sections";
        [[PXPlex shared] get:path done:^(NSDictionary *mc, NSError *err) {
            for (NSDictionary *d in mc[@"Directory"]) PXLog(@"section %@ %@ %@", d[@"key"], d[@"type"], d[@"title"]);
            for (NSDictionary *d in mc[@"Metadata"]) {
                NSDictionary *m = [d[@"Media"] firstObject];
                PXLog(@"item %@ %@ %@ (%@) offset=%@ %@ %@ %@ guid=%@ Guid=%lu thumb=%@ art=%@", d[@"ratingKey"], d[@"type"], d[@"title"], d[@"year"], d[@"viewOffset"],
                      m[@"videoResolution"], m[@"videoCodec"], m[@"audioCodec"], d[@"guid"], (unsigned long)[d[@"Guid"] count], d[@"thumb"], d[@"art"]);
            }
            if (err) PXLog(@"items: %@", err);
        }];
    });
    PXDebugRegister(@"play", ^(NSArray *a) {
        if (!a.count) return;
        PXItem *it = [PXItem itemWithJSON:@{ @"ratingKey": a[0], @"type": @"movie" }];
        id stack = [[PXCls("BRApplicationStackManager") singleton] stack];
        [stack pushController:PXHostControllerForScreen(PXPlayerScreenNew(it, a.count > 1 ? [a[1] doubleValue] : -1))];
    });
    PXDebugRegister(@"open", ^(NSArray *a) {
        if (!a.count) return;
        id stack = [[PXCls("BRApplicationStackManager") singleton] stack];
        [stack pushController:PXHostControllerForScreen(PXScreenForRatingKey(a[0]))];
    });
    // pget <path>: GET on the primary server, logs the shape of the answer (no token).
    PXDebugRegister(@"pget", ^(NSArray *a) {
        if (!a.count) return;
        [[PXPlex shared].primaryServer get:a[0] done:^(NSDictionary *mc, NSError *err) {
            NSMutableArray *parts = [NSMutableArray array];
            [mc enumerateKeysAndObjectsUsingBlock:^(id k, id v, BOOL *stop) {
                if ([v isKindOfClass:[NSArray class]]) [parts addObject:[NSString stringWithFormat:@"%@[%lu]", k, (unsigned long)[v count]]];
                else if (![v isKindOfClass:[NSDictionary class]]) [parts addObject:[NSString stringWithFormat:@"%@=%@", k, v]];
            }];
            PXLog(@"pget %@ -> %@ %@", a[0], err ? err.localizedDescription : @"ok", [parts componentsJoinedByString:@" "]);
        }];
    });
    PXDebugRegister(@"fetch", ^(NSArray *a) {
        if (!a.count) return;
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:a[0]]];
        if (a.count > 1) req.HTTPMethod = a[1];
        [req setValue:@"application/json" forHTTPHeaderField:@"Accept"];
        NSDate *t0 = [NSDate date];
        [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
            PXLog(@"fetch %@ -> %ld in %.0f ms err=%@", a[0], (long)[(NSHTTPURLResponse *)r statusCode], -[t0 timeIntervalSinceNow] * 1000, e);
        }] resume];
    });
}
#endif
