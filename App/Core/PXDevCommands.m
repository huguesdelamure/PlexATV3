// Plex-specific development commands for the SSH debug channel (DEBUG builds).
//   items [sectionKey | /raw/path]   log sections or items
//   play <ratingKey> [offset]        open the player on top of the stack
//   fetch <url> [METHOD]             HTTP(S) reachability test with the system TLS stack

#ifdef DEBUG
#import "PXDebug.h"
#import "PXBackRow.h"
#import "PXRouter.h"
#import "PXPlex.h"
#import <objc/message.h>
#import <dlfcn.h>
#import "PXServer.h"
#import "PXItem.h"
#import "PXSettings.h"
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
    // cec: IORegistry entries whose class or name looks like CEC / HDMI
    // (is there a CEC controller to talk to?). IOKit resolved at run time.
    PXDebugRegister(@"cec", ^(NSArray *a) {
        void *h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
        if (!h) { PXLog(@"cec: no IOKit"); return; }
        typedef unsigned int io_t;
        io_t (*getRoot)(unsigned int) = dlsym(h, "IORegistryGetRootEntry");
        int (*createIter)(io_t, const char *, unsigned int, io_t *) = dlsym(h, "IORegistryEntryCreateIterator");
        io_t (*next)(io_t) = dlsym(h, "IOIteratorNext");
        int (*getClass)(io_t, char *) = dlsym(h, "IOObjectGetClass");
        int (*getName)(io_t, char *) = dlsym(h, "IORegistryEntryGetName");
        int (*release)(io_t) = dlsym(h, "IOObjectRelease");
        unsigned int *masterPort = dlsym(h, "kIOMasterPortDefault");
        if (!getRoot || !createIter || !next || !getClass || !getName) { PXLog(@"cec: IOKit symbols missing"); return; }
        io_t iter = 0;
        if (createIter(getRoot(masterPort ? *masterPort : 0), "IOService", 1 /* recursive */, &iter) != 0) { PXLog(@"cec: no iterator"); return; }
        NSUInteger total = 0, hits = 0;
        for (io_t o; (o = next(iter)); release(o)) {
            char cls[128] = {0}, name[128] = {0};
            getClass(o, cls); getName(o, name);
            total++;
            NSString *c = @(cls), *n = @(name);
            if ([c.lowercaseString containsString:@"cec"] || [n.lowercaseString containsString:@"cec"] ||
                [c.lowercaseString containsString:@"hdmi"] || [n.lowercaseString containsString:@"hdmi"]) {
                hits++;
                PXLog(@"cec: %@ (%@)", c, n);
            }
        }
        release(iter);
        PXLog(@"cec: %lu matching entries out of %lu", (unsigned long)hits, (unsigned long)total);
    });
    // markers: intro / credits markers of the first on-deck episodes, as the
    // player loads them.
    PXDebugRegister(@"markers", ^(NSArray *a) {
        PXServer *sv = [PXPlex shared].primaryServer;
        [sv get:@"/library/onDeck?X-Plex-Container-Size=5" done:^(NSDictionary *mc, NSError *err) {
            NSArray *items = [PXItem itemsWithJSON:mc[@"Metadata"]];
            PXLog(@"markers: %lu on deck items %@", (unsigned long)items.count, err.localizedDescription ?: @"");
            for (PXItem *it in items) {
                [sv metadata:it.ratingKey done:^(NSDictionary *m, NSError *e) {
                    PXItem *full = m ? [PXItem itemWithJSON:m] : nil;
                    NSMutableArray *kinds = [NSMutableArray array];
                    for (NSDictionary *mk in full.markers) [kinds addObject:[NSString stringWithFormat:@"%@ %.0f-%.0f", mk[@"type"], [mk[@"start"] doubleValue], [mk[@"end"] doubleValue]]];
                    PXLog(@"markers: [%@ offset=%.0f views=%@] '%@' %@ -> %@", it.ratingKey, full.viewOffset, full.raw[@"viewCount"] ?: @0, it.grandparentTitle ?: it.title, it.episodeCode ?: @"", kinds.count ? [kinds componentsJoinedByString:@", "] : @"none");
                }];
            }
        }];
    });
    // apitest: the server APIs behind history, library hubs, cinema trailers and
    // artist pages, read only.
    PXDebugRegister(@"apitest", ^(NSArray *a) {
        PXServer *sv = [PXPlex shared].primaryServer;
        [sv get:@"/status/sessions/history/all?sort=viewedAt:desc&accountID=1&X-Plex-Container-Size=5" done:^(NSDictionary *mc, NSError *e) {
            PXLog(@"apitest: history %lu %@", (unsigned long)[mc[@"Metadata"] count], e.localizedDescription ?: @"ok");
        }];
        [sv get:@"/library/sections" done:^(NSDictionary *mc, NSError *e) {
            for (NSDictionary *d in mc[@"Directory"]) {
                NSString *k = [d[@"key"] description], *type = d[@"type"];
                if ([type isEqual:@"movie"]) {
                    [sv get:[NSString stringWithFormat:@"/hubs/sections/%@?count=5", k] done:^(NSDictionary *h, NSError *e2) {
                        NSUInteger withItems = 0;
                        for (NSDictionary *hub in h[@"Hub"]) if ([hub[@"Metadata"] count]) withItems++;
                        PXLog(@"apitest: hubs of '%@': %lu rows, %lu with titles %@", d[@"title"], (unsigned long)[h[@"Hub"] count], (unsigned long)withItems, e2.localizedDescription ?: @"");
                    }];
                    [sv get:[NSString stringWithFormat:@"/library/sections/%@/all?type=1&X-Plex-Container-Size=1", k] done:^(NSDictionary *m1, NSError *e3) {
                        NSDictionary *movie = [m1[@"Metadata"] firstObject];
                        if (movie) [sv trailersBefore:movie count:2 done:^(NSArray *items, NSError *e4) {
                            NSMutableArray *types = [NSMutableArray array];
                            for (PXItem *it in items) [types addObject:[NSString stringWithFormat:@"%@:%@", it.raw[@"type"], it.title]];
                            PXLog(@"apitest: trailers queue %@", [types componentsJoinedByString:@" | "]);
                        }];
                    }];
                }
                if ([type isEqual:@"artist"]) {
                    [sv get:[NSString stringWithFormat:@"/library/sections/%@/all?type=8&X-Plex-Container-Size=1", k] done:^(NSDictionary *m1, NSError *e3) {
                        NSDictionary *artist = [m1[@"Metadata"] firstObject];
                        if (!artist) return;
                        NSString *p = [NSString stringWithFormat:@"/library/sections/%@/all?type=10&artist.id=%@&sort=viewCount:desc&X-Plex-Container-Size=5", k, artist[@"ratingKey"]];
                        [sv get:p done:^(NSDictionary *t, NSError *e4) {
                            NSMutableArray *names = [NSMutableArray array];
                            for (NSDictionary *tr in t[@"Metadata"]) [names addObject:[NSString stringWithFormat:@"%@ (%@)", tr[@"title"], tr[@"grandparentTitle"]]];
                            PXLog(@"apitest: popular tracks of '%@': %@ %@", artist[@"title"], [names componentsJoinedByString:@", "], e4.localizedDescription ?: @"");
                        }];
                    }];
                }
            }
        }];
    });
    // set <key> <value|->: change a setting without going through the menus.
    PXDebugRegister(@"set", ^(NSArray *a) {
        if (a.count < 2) return;
        id v = [a[1] isEqual:@"-"] ? nil : a[1];
        if ([v rangeOfCharacterFromSet:[[NSCharacterSet decimalDigitCharacterSet] invertedSet]].location == NSNotFound) v = @([v intValue]);
        PXSettingSet(a[0], v);
        PXLog(@"set %@ = %@", a[0], v ?: @"(none)");
    });
    // saver: is the screensaver showing (no screen capture needed).
    PXDebugRegister(@"saver", ^(NSArray *a) {
        id mgr = [PXCls("ATVScreenSaverManager") singleton];
        BOOL showing = [mgr respondsToSelector:@selector(isScreenSaverShowing)] && ((BOOL (*)(id, SEL))objc_msgSend)(mgr, @selector(isScreenSaverShowing));
        PXLog(@"saver: %@", showing ? @"SHOWING" : @"hidden");
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
