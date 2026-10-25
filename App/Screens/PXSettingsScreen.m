// Settings: server choice, transcode quality, account.

#import "PXRouter.h"
#import "PXBackRow.h"
#import "PXKeyboard.h"
#import "PXServer.h"
#import "PXUI.h"
#import "PXListLayer.h"
#import "PXPlex.h"
#import "PXSettings.h"
#import "PXLog.h"
#import "PXTrackPrefs.h"
#import "PXAmbientPlex.h"

@interface PXSettingsScreen : PXScreen
@end

static BOOL gFocusLanguage;           // set across the rebuild after a language change
static const NSInteger kLanguageRow = 5;  // index of "Langue" in buildMain

@implementation PXSettingsScreen {
    PXListLayer *_list;
    CATextLayer *_info;
    CALayer *_infoPanel;
    NSArray *_servers;
    BOOL _pickingServer;
}

- (instancetype)initEmbedded:(BOOL)embedded {
    if ((self = [super init])) {
        self.embedded = embedded;
        [self.layer addSublayer:[[PXAmbientLayer alloc] initWithFrame:self.layer.bounds style:PXAmbientBlurOnly]];
        CATextLayer *title = PXText(PXFontHeavy(64), PXColorText());
        title.string = PXL(@"Réglages");
        title.frame = CGRectMake(160, 90, 1200, 70);
        title.hidden = embedded;          // the tab already says "Réglages"
        [self.layer addSublayer:title];
        _list = [[PXListLayer alloc] initWithFrame:CGRectMake(160, 220, 1100, 720) rowHeight:80];
        [self.layer addSublayer:_list];
        // Info card: text inset from the panel edges, panel fitted to the text.
        _infoPanel = [CALayer layer];
        _infoPanel.backgroundColor = PXColorWhite(0.05);
        _infoPanel.cornerRadius = 16;
        _infoPanel.frame = CGRectMake(1320, 230, 460, 200);
        [self.layer addSublayer:_infoPanel];
        _info = PXText(PXFont(26), PXColorTextDim());
        _info.wrapped = YES;
        _info.frame = CGRectMake(30, 26, 400, 150);
        [_infoPanel addSublayer:_info];
        [self buildMain];
        if (gFocusLanguage) { gFocusLanguage = NO; _list.focusIndex = kLanguageRow; }
    }
    return self;
}

- (void)buildMain {
    _pickingServer = NO;
    PXPlex *plex = [PXPlex shared];
    __weak PXSettingsScreen *weak = self;
    int br = [PXSettingGet(@"maxBitrate") intValue] ?: 8000;
    NSString *uri = [PXPlex shared].primaryServer.uri ?: @"";
    NSArray *rows = @[
        [PXListRow title:PXL(@"Serveur") value:plex.serverName ?: PXL(@"aucun") action:^{ [weak pickServer]; }],
        [PXListRow title:PXL(@"Serveurs sur l'accueil") value:[NSString stringWithFormat:@"%lu", (unsigned long)plex.selectedServers.count] action:^{
            [weak push:PXServersScreenNew(^{ [weak buildMain]; })];
        }],
        [PXListRow title:PXL(@"Qualité de transcodage") value:PXLF(@"%.0f Mb/s", br / 1000.0) action:^{
            NSArray *steps = @[ @3000, @4000, @8000, @12000, @20000 ];
            NSUInteger i = [steps indexOfObject:@(br)];
            PXSettingSet(@"maxBitrate", steps[(i == NSNotFound ? 2 : i + 1) % steps.count]);
            [weak buildMain];
        }],
        [PXListRow title:PXL(@"Langue audio") value:PXChoiceLabel(PXAudioLangChoices(), PXSettingGet(@"audioLang") ?: @"account") action:^{
            [weak cycle:@"audioLang" choices:PXAudioLangChoices()];
        }],
        [PXListRow title:PXL(@"Sous-titres") value:PXChoiceLabel(PXSubModeChoices(), PXSettingGet(@"subMode") ?: @"account") action:^{
            [weak cycle:@"subMode" choices:PXSubModeChoices()];
        }],
        [PXListRow title:PXL(@"Langue") value:[self languageLabel] action:^{ [weak nextLanguage]; }],
        [PXListRow title:PXL(@"Clavier") value:[self keyboardLabel] action:^{ [weak nextKeyboard]; }],
        [PXListRow title:PXL(@"Se déconnecter de plex.tv") value:@"" action:^{
            [[PXPlex shared] signOut];
            [weak pop];
        }],
    ];
    _list.rows = rows;
    NSString *conn = @"-";
    if (uri.length) {
        BOOL https = [uri hasPrefix:@"https"], v6 = [uri containsString:@"://"] && [[uri componentsSeparatedByString:@"://"].lastObject componentsSeparatedByString:@"-"].count > 6;
        BOOL relay = [uri containsString:@"relay"];
        // Whole phrases, so each language can order the words.
        NSString *kind = relay ? (https ? PXL(@"relais Plex chiffré (HTTPS)") : PXL(@"relais Plex (HTTP)"))
                               : (https ? PXL(@"directe chiffrée (HTTPS)") : PXL(@"directe (HTTP)"));
        conn = v6 ? PXLF(@"%@ en IPv6", kind) : kind;
    }
    NSString *text = PXLF(@"Connexion : %@\n\nQualité : débit maximum demandé au serveur quand il transcode (H.265/4K → H.264 1080p). Baissez-le si la lecture saccade.\n\nPlex pour Apple TV 3, version %@",
                      conn,
                      [[NSBundle bundleForClass:[self class]] objectForInfoDictionaryKey:@"CFBundleShortVersionString"]);
    PXSetText(_info, text);
    CGFloat h = ceil(PXTextHeight(text, PXFont(26), 400)) + 4;
    PXNoAnim(^{
        self->_info.frame = CGRectMake(30, 26, 400, h);
        self->_infoPanel.frame = CGRectMake(1320, 230, 460, h + 52);
    });
}

#pragma mark - Language and keyboard

- (NSString *)languageLabel {
    NSString *pref = PXSettingGet(@"uiLanguage") ?: @"auto";
    return [pref isEqual:@"auto"] ? PXLF(@"Automatique (%@)", PXLanguageName(PXLanguage())) : PXLanguageName(pref);
}

- (void)nextLanguage {
    NSArray *order = [@[ @"auto" ] arrayByAddingObjectsFromArray:PXSupportedLanguages()];
    NSUInteger i = [order indexOfObject:PXSettingGet(@"uiLanguage") ?: @"auto"];
    PXSettingSet(@"uiLanguage", order[(i == NSNotFound ? 0 : i + 1) % order.count]);
    PXLog(@"settings: UI language %@", PXLanguage());
    // Every screen draws its texts once: rebuild the app in the new language,
    // back on this tab with the focus on this row.
    gFocusLanguage = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        id stack = [[PXCls("BRApplicationStackManager") singleton] stack];
        [stack swapController:PXHostControllerForScreen(PXHomeScreenOnSettings())];
    });
}

- (NSString *)keyboardLabel {
    NSString *pref = PXSettingGet(@"keyboard") ?: @"auto";
    NSString *name = PXKeyboardLayouts()[PXKeyboardLayout()][@"name"];
    return [pref isEqual:@"auto"] ? PXLF(@"Automatique (%@)", name) : name;
}

- (void)nextKeyboard {
    NSArray *order = PXKeyboardLayoutOrder();
    NSUInteger i = [order indexOfObject:PXSettingGet(@"keyboard") ?: @"auto"];
    PXSettingSet(@"keyboard", order[(i == NSNotFound ? 0 : i + 1) % order.count]);
    NSInteger focus = _list.focusIndex;
    [self buildMain];
    _list.focusIndex = focus;
}

// Next value of a setting among its choices.
- (void)cycle:(NSString *)key choices:(NSArray *)choices {
    NSString *cur = PXSettingGet(key) ?: [choices.firstObject firstObject];
    NSUInteger i = 0;
    for (NSUInteger j = 0; j < choices.count; j++) if ([choices[j][0] isEqual:cur]) i = j;
    PXSettingSet(key, choices[(i + 1) % choices.count][0]);
    NSInteger focus = _list.focusIndex;
    [self buildMain];
    _list.focusIndex = focus;
}

- (void)pickServer {
    _pickingServer = YES;
    _list.rows = @[ [PXListRow title:PXL(@"Recherche des serveurs…") value:@"" action:nil] ];
    __weak PXSettingsScreen *weak = self;
    [[PXPlex shared] fetchServers:^(NSArray *servers, NSError *err) {
        PXSettingsScreen *me = weak;
        if (!me || !me->_pickingServer) return;
        NSMutableArray *rows = [NSMutableArray array];
        NSString *current = PXSettingGet(@"serverId");
        for (NSDictionary *s in servers) {
            NSString *who = [s[@"owned"] boolValue] ? @"" : (s[@"sourceTitle"] ?: PXL(@"partagé"));
            NSString *twin = PXServerTwinLabel(s, servers);
            if (twin) who = who.length ? [NSString stringWithFormat:@"%@ · %@", twin, who] : twin;
            PXListRow *r = [PXListRow title:s[@"name"] value:who action:^{
                PXListRow *wait = [PXListRow title:PXLF(@"Connexion à %@…", s[@"name"]) value:@"" action:nil];
                PXSettingsScreen *me2 = weak; if (me2) me2->_list.rows = @[ wait ];
                [[PXPlex shared] connectToServer:s done:^(id conn, NSError *e) {
                    if (e) PXLog(@"settings: %@ unreachable: %@", s[@"name"], e.localizedDescription);
                    [weak buildMain];
                }];
            }];
            r.checked = [s[@"clientIdentifier"] isEqual:current];
            [rows addObject:r];
        }
        if (!rows.count) [rows addObject:[PXListRow title:err ? err.localizedDescription : PXL(@"Aucun serveur") value:@"" action:nil]];
        me->_list.rows = rows;
    }];
}

- (void)focusChanged {
    _list.active = self.hasFocus;
}

- (BOOL)handleKey:(PXKey)key {
    switch (key) {
        case PXKeyUp: return [_list handleUp] || !self.embedded;   // top edge: back to the tabs
        case PXKeyDown: [_list handleDown]; return YES;
        case PXKeySelect: [_list activate]; return YES;
        case PXKeyMenu:
            if (_pickingServer) { [self buildMain]; return YES; }
            return NO;
        default: return NO;
    }
}

@end

PXScreen *PXSettingsScreenNew(BOOL embedded) { return [[PXSettingsScreen alloc] initEmbedded:embedded]; }
