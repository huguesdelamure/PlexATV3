// plex.tv account linking: shows a PIN, polls until it is entered on
// plex.tv/link, then picks a server (owned first) and connects to it.

#import "PXRouter.h"
#import "PXUI.h"
#import "PXPlex.h"
#import "PXLog.h"
#import "PXAmbientPlex.h"

@interface PXLinkScreen : PXScreen
@property (nonatomic, copy) void (^completion)(void);
@end

@implementation PXLinkScreen {
    CATextLayer *_code, *_status;
    NSMutableArray *_boxes;     // per-character boxes
    NSNumber *_pinId;
    NSDate *_pinTime;
    BOOL _done, _gone;
}

- (instancetype)init {
    if ((self = [super init])) {
        PXAmbientLayer *ambient = [[PXAmbientLayer alloc] initWithFrame:self.layer.bounds style:PXAmbientBlurOnly];
        [self.layer addSublayer:ambient];
        CATextLayer *head = PXText(PXFontHeavy(64), PXColorText());
        head.alignmentMode = kCAAlignmentCenter;
        head.string = PXL(@"Associez votre compte Plex");
        head.frame = CGRectMake(160, 200, 1600, 80);
        CATextLayer *title = PXText(PXFont(34), PXColorTextDim());
        title.alignmentMode = kCAAlignmentCenter;
        title.wrapped = YES;
        title.string = PXL(@"Sur un téléphone ou un ordinateur, ouvrez plex.tv/link et saisissez ce code");
        title.frame = CGRectMake(260, 300, 1400, 100);
        _code = PXText(PXFontHeavy(10), PXColorText());   // kept for state, boxes display it
        _code.hidden = YES;
        _status = PXText(PXFontMedium(30), PXColorTextDim());
        _status.alignmentMode = kCAAlignmentCenter;
        _status.frame = CGRectMake(160, 740, 1600, 44);
        for (CALayer *l in @[ head, title, _code, _status ]) [self.layer addSublayer:l];
        // Four rounded boxes, one per PIN character.
        _boxes = [NSMutableArray array];
        CGFloat bw = 170, gap = 30, x0 = (1920 - (4 * bw + 3 * gap)) / 2;
        for (int i = 0; i < 4; i++) {
            CALayer *box = [CALayer layer];
            box.frame = CGRectMake(x0 + i * (bw + gap), 450, bw, 210);
            box.cornerRadius = 22;
            box.backgroundColor = PXColorWhite(0.1);
            box.borderColor = PXColorWhite(0.25);
            box.borderWidth = 2;
            CATextLayer *ch = PXText(PXFontHeavy(130), PXColorText());
            ch.alignmentMode = kCAAlignmentCenter;
            ch.frame = CGRectMake(0, (210 - PXFontHeavy(130).lineHeight) / 2, bw, PXFontHeavy(130).lineHeight + 4);
            [box addSublayer:ch];
            [self.layer addSublayer:box];
            [_boxes addObject:ch];
        }
        CALayer *spin = PXSpinner(44);
        spin.position = CGPointMake(960, 830);
        [self.layer addSublayer:spin];
    }
    return self;
}

- (void)didAppear {
    [super didAppear];
    if (!_pinId && !_done) [self requestPin];
}

- (void)didPop { _gone = YES; [super didPop]; }

- (void)requestPin {
    PXSetText(_status, PXL(@"Demande du code…"));
    __weak PXLinkScreen *weak = self;
    [[PXPlex shared] createPin:^(NSDictionary *pin, NSError *err) {
        PXLinkScreen *me = weak;
        if (!me || me->_gone) return;
        if (err || !pin[@"code"]) {
            PXSetText(me->_status, PXLF(@"plex.tv injoignable (%@), nouvel essai…", err.localizedDescription));
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [weak requestPin]; });
            return;
        }
        PXSetText(me->_code, pin[@"code"]);
        NSString *code = pin[@"code"];
        for (NSUInteger i = 0; i < me->_boxes.count; i++) {
            PXSetText(me->_boxes[i], i < code.length ? [code substringWithRange:NSMakeRange(i, 1)] : @"");
            PXSpringScale([me->_boxes[i] superlayer], 1.0);
        }
        PXSetText(me->_status, PXL(@"En attente de la validation…"));
        me->_pinId = pin[@"id"];
        me->_pinTime = [NSDate date];
        [me poll];
    }];
}

- (void)poll {
    if (_done || _gone) return;
    if ([_pinTime timeIntervalSinceNow] < -840) { [self requestPin]; return; }   // PINs expire after ~15 min
    __weak PXLinkScreen *weak = self;
    [[PXPlex shared] checkPin:_pinId done:^(NSDictionary *pin, NSError *err) {
        PXLinkScreen *me = weak;
        if (!me || me->_done || me->_gone) return;
        NSString *token = [pin[@"authToken"] isKindOfClass:[NSString class]] ? pin[@"authToken"] : nil;
        if (token.length) {
            me->_done = YES;
            [[PXPlex shared] saveAuthToken:token];
            PXLog(@"link: account linked");
            PXSetText(me->_status, PXL(@"Compte associé. Recherche du serveur…"));
            [me findServer];
            return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [weak poll]; });
    }];
}

- (void)findServer {
    __weak PXLinkScreen *weak = self;
    [[PXPlex shared] fetchServers:^(NSArray *servers, NSError *err) {
        PXLinkScreen *me = weak;
        if (!me) return;
        NSDictionary *pick = nil;
        for (NSDictionary *s in servers) if ([s[@"owned"] boolValue]) { pick = s; break; }
        if (!pick) pick = servers.firstObject;
        if (!pick) { PXSetText(me->_status, PXL(@"Aucun serveur Plex sur ce compte.")); return; }
        PXSetText(me->_status, PXLF(@"Connexion à %@…", pick[@"name"]));
        [[PXPlex shared] connectToServer:pick done:^(id conn, NSError *e) {
            PXLinkScreen *me2 = weak;
            if (!me2) return;
            if (e) { PXSetText(me2->_status, [NSString stringWithFormat:@"%@ : %@", pick[@"name"], e.localizedDescription]); return; }
            void (^completion)(void) = me2.completion;
            [me2 pop];
            if (completion) completion();
        }];
    }];
}

@end

PXScreen *PXLinkScreenNew(void (^completion)(void)) {
    PXLinkScreen *s = [PXLinkScreen new];
    s.completion = completion;
    return s;
}
