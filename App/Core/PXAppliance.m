// Entry point of PlexATV3: the appliance principal class, created at runtime
// as a subclass of BRBaseAppliance (BackRow classes are not exported by the
// AppleTV binary, see PXRuntime.h).

#import <Foundation/Foundation.h>
#import "PXServer.h"
#import "PXRuntime.h"
#import "PXLog.h"
#import "PXUI.h"
#import "PXRouter.h"
#import "PXImageCache.h"
#import "PXShelfProvider.h"
#import "PXPlex.h"
#import "PXItem.h"
#import "PXBackRow.h"
#ifdef DEBUG
#import "PXDebug.h"
void PXRegisterDevCommands(void);
#endif

@interface NSObject (PXBackRowCategory)
- (id)categoryWithName:(id)name identifier:(id)ident preferredOrder:(float)order;
@end

@interface PXApplianceTemplate : NSObject <PXShelfProvider>
@end

@implementation PXApplianceTemplate

- (id)applianceCategories {
    id cat = [PXCls("BRApplianceCategory") categoryWithName:@"Plex" identifier:@"plex-main" preferredOrder:0.0f];
    // beigelist shows a category list (BLAppLegacyCategoryController) for
    // appliances like ours and asks for the categories while building it:
    // replace that list by the app right away (single category anyway).
    __weak id weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf px_skipLoaderList]; });
    return cat ? @[ cat ] : @[];
}

- (void)px_skipLoaderList {
    id stack = [[PXCls("BRApplicationStackManager") singleton] stack];
    id top = [stack peekController];
    if (![NSStringFromClass([top class]) hasPrefix:@"BLAppLegacy"]) return;
    id owner = nil;
    @try { owner = [top valueForKey:@"legacyAppliance"]; } @catch (NSException *e) {}
    if (owner && owner != self) return;   // another app's list
    PXLog(@"appliance: replacing %@ by the app", NSStringFromClass([top class]));
    [stack swapController:PXHostControllerForScreen(PXHomeScreenNew())];
}

- (id)controllerForIdentifier:(id)identifier args:(id)args {
    [[PXImageCache shared] trimDiskCache];
    return PXHostControllerForScreen(PXHomeScreenNew());
}

- (id)applianceController {
    return PXHostControllerForScreen(PXHomeScreenNew());
}

// beigelist (third-party appliance loader on ATV 6/7) pushes -rootController
// directly when an appliance provides it, instead of its category list.
- (id)rootController {
    [[PXImageCache shared] trimDiskCache];
    return PXHostControllerForScreen(PXHomeScreenNew());
}

#pragma mark PXShelfProvider (launcher Top Shelf)

- (void)shelfContent:(void (^)(NSDictionary *))completion {
    PXPlex *plex = [PXPlex shared];
    if (!plex.isLinked || !plex.hasServer) { completion(nil); return; }
    [plex get:@"/hubs?count=12" done:^(NSDictionary *mc, NSError *err) {
        NSDictionary *pick = nil;
        // Continue watching first, else on deck, else recently added.
        for (NSString *wanted in @[ @"home.continue", @"home.ondeck", @"home.movies.recent" ])
            for (NSDictionary *h in mc[@"Hub"])
                if (!pick && [h[@"hubIdentifier"] isEqual:wanted] && [h[@"Metadata"] count]) pick = h;
        if (!pick) { completion(nil); return; }
        BOOL wide = ![pick[@"hubIdentifier"] isEqual:@"home.movies.recent"];
        NSMutableArray *items = [NSMutableArray array];
        for (PXItem *it in [PXItem itemsWithJSON:pick[@"Metadata"]]) {
            NSString *img = wide ? it.landscapePath : it.posterPath;
            NSURL *imageURL = [it.server imageURL:img width:wide ? 480 : 240 height:wide ? 270 : 360];
            NSURL *bg = it.art ? [it.server artURL:it.art width:1280 height:720 blur:0] : nil;
            // "ratingKey@server" when the item is not on the primary server (opaque for the launcher).
            NSString *ident = it.server == plex.primaryServer ? it.ratingKey : [NSString stringWithFormat:@"%@@%@", it.ratingKey, it.server.identifier];
            NSMutableDictionary *d = [@{ @"id": ident ?: @"", @"title": it.shelfTitle ?: @"",
                                         @"subtitle": (wide && it.remainingText ? (it.type == PXItemEpisode ? [NSString stringWithFormat:@"%@ · %@", it.episodeCode, it.remainingText] : it.remainingText) : it.shelfSubtitle) ?: @"",
                                         @"wide": @(wide), @"progress": @(it.progress) } mutableCopy];
            if (imageURL) d[@"image"] = imageURL.absoluteString;
            if (bg) d[@"background"] = bg.absoluteString;
            if ([it.raw[@"UltraBlurColors"] isKindOfClass:[NSDictionary class]]) d[@"colors"] = it.raw[@"UltraBlurColors"];
            [items addObject:d];
        }
        completion(@{ @"title": pick[@"title"] ?: @"Plex", @"items": items });
    }];
}

- (id)controllerForShelfItem:(NSString *)identifier play:(BOOL)play {
    // Minimal item: the screens fetch full metadata themselves.
    NSArray *parts = [identifier ?: @"" componentsSeparatedByString:@"@"];
    NSString *rk = parts.firstObject, *sid = parts.count > 1 ? parts[1] : nil;
    NSMutableDictionary *json = [@{ @"ratingKey": rk ?: @"", @"type": @"movie" } mutableCopy];
    if (sid) json[@"_server"] = sid;
    PXItem *it = [PXItem itemWithJSON:json];
    PXScreen *s = play ? PXPlayerScreenNew(it, -1) : PXScreenForRatingKeyOnServer(rk, it.server);
    return PXHostControllerForScreen(s);
}

@end

static NSUncaughtExceptionHandler *gPrevHandler;
static void PXExceptionHandler(NSException *e) {
    PXLog(@"UNCAUGHT %@: %@\n%@", e.name, e.reason, [e.callStackSymbols componentsJoinedByString:@"\n"]);
    [NSThread sleepForTimeInterval:0.3];   // let the async log writer flush
    if (gPrevHandler) gPrevHandler(e);
}

// Settings used to live in Caches/PlexATV (pre-split name): keep the login.
static void migrateOldData(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dst = [PXDataDir() stringByAppendingPathComponent:@"settings.plist"];
    NSString *src = @"/var/mobile/Library/Caches/PlexATV/settings.plist";
    if (![fm fileExistsAtPath:dst] && [fm fileExistsAtPath:src]) {
        [fm copyItemAtPath:src toPath:dst error:NULL];
        PXLog(@"migrated settings from %@", src);
    }
}

// Home screen tile icon. ATV 7.x asks BRApplianceIconManager for every tile;
// for a merchant tile like ours it loads <bundle id>@1080.png from its cache
// (Caches/AppleTV/MainMenu), normally filled by downloading menuIconURL, which
// never happens for a file:// URL: the tile stays a black brick. Put our icon
// there ourselves, in the stock format (284x161, 1 px transparent margin,
// rounded corners), before the menu is built.
static void PXInstallMenuIcon(void) {
    NSString *src = [PXKitBundle() pathForResource:@"MenuIcon" ofType:@"png"];
    NSString *dir = @"/var/mobile/Library/Caches/AppleTV/MainMenu";
    NSString *dst = [dir stringByAppendingPathComponent:[PXKitBundle().bundleIdentifier stringByAppendingString:@"@1080.png"]];
    NSData *want = src ? [NSData dataWithContentsOfFile:src] : nil;
    if (!want || [[NSData dataWithContentsOfFile:dst] isEqualToData:want]) return;
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
    BOOL ok = [want writeToFile:dst atomically:YES];
    PXLog(@"tile icon: %@ %@", ok ? @"installed" : @"FAILED to write", dst);
}

__attribute__((constructor)) static void PXInit(void) {
    @autoreleasepool {
        PXLog(@"---- PlexATV3 %@ loaded into %@ ----", [PXKitBundle() objectForInfoDictionaryKey:@"CFBundleShortVersionString"],
              [[NSProcessInfo processInfo] processName]);
        PXRegisterFonts();
        migrateOldData();
        gPrevHandler = NSGetUncaughtExceptionHandler();
        NSSetUncaughtExceptionHandler(PXExceptionHandler);
        const char *base = objc_getClass("BRBaseAppliance") ? "BRBaseAppliance" : "BRAppliance";
        Class c = PXCreateSubclass("PXAppliance", base, [PXApplianceTemplate class]);
        PXLog(@"PXAppliance created: %@ (super %s)", c, base);
        PXInstallMenuIcon();
#ifdef DEBUG
        dispatch_async(dispatch_get_main_queue(), ^{ PXRegisterDevCommands(); PXDebugStart(); });
#endif
    }
}
