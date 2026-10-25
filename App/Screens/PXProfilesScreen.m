// Plex Home profile picker ("Qui regarde ?") with the PIN pad of protected
// profiles. Shown at launch (setting "profileAtLaunch" = "ask") or from
// Réglages. At launch, Menu leaves the app: going back would show the home
// of the previous profile without its PIN.

#import "PXRouter.h"
#import "PXBackRow.h"
#import "PXUI.h"
#import "PXAmbientLayer.h"
#import "PXImageCache.h"
#import "PXPlex.h"
#import "PXLog.h"

static const CGFloat kAvatar = 200, kAvatarGap = 80, kAvatarY = 400;

@interface PXProfilesScreen : PXScreen
@property (nonatomic, copy) void (^completion)(void);
@property (nonatomic) BOOL atLaunch;
@end

@implementation PXProfilesScreen {
    NSArray *_users;
    NSMutableArray *_cells;        // CALayer per user
    NSInteger _index;
    CALayer *_title;
    CALayer *_spinner;
    // PIN pad
    NSDictionary *_pinUser;
    NSMutableString *_pin;
    CALayer *_pad;
    NSMutableArray *_keys;         // CALayer, 12 keys: 1-9, (empty), 0, ⌫
    NSMutableArray *_dots;
    CATextLayer *_pinError;
    NSInteger _key;
    BOOL _busy;
}

- (void)setup {
    [self.layer addSublayer:[[PXAmbientLayer alloc] initWithFrame:self.layer.bounds style:PXAmbientBlurOnly]];
    _title = PXAsyncLabel(PXL(@"Qui regarde ?"), PXFontHeavy(64), PXColorText(), CGRectMake(0, 220, 1920, 80), 1, YES);
    [self.layer addSublayer:_title];
    _cells = [NSMutableArray array];
    _users = [PXPlex shared].homeUsers;
    NSString *current = [PXPlex shared].currentHomeUser[@"uuid"];
    for (NSUInteger i = 0; i < _users.count; i++) if ([_users[i][@"uuid"] isEqual:current]) _index = i;
    [self buildCells];
    __weak PXProfilesScreen *weak = self;
    [[PXPlex shared] fetchHomeUsers:^(NSArray *users, NSError *err) {
        PXProfilesScreen *me = weak;
        if (!me || !users.count || me->_pinUser || [users isEqual:me->_users]) return;
        me->_users = users;
        me->_index = MIN(me->_index, (NSInteger)users.count - 1);
        [me buildCells];
    }];
}

static NSString *initials(NSString *name) {
    NSMutableString *s = [NSMutableString string];
    for (NSString *w in [name componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]) {
        if (w.length && s.length < 2) [s appendString:[[w substringToIndex:1] uppercaseString]];
    }
    return s.length ? s : @"?";
}

- (void)buildCells {
    for (CALayer *c in _cells) [c removeFromSuperlayer];
    [_cells removeAllObjects];
    NSInteger n = _users.count;
    CGFloat total = n * kAvatar + MAX(0, n - 1) * kAvatarGap;
    CGFloat x = (1920 - total) / 2;
    NSArray *palette = @[ @"e5a00d", @"3f7fbf", @"4caf7d", @"c0556a", @"8e6cc4", @"d97a3a" ];
    for (NSInteger i = 0; i < n; i++) {
        NSDictionary *u = _users[i];
        CALayer *cell = [CALayer layer];
        cell.frame = CGRectMake(x + i * (kAvatar + kAvatarGap), kAvatarY, kAvatar, kAvatar + 110);
        CALayer *circle = [CALayer layer];
        circle.frame = CGRectMake(0, 0, kAvatar, kAvatar);
        circle.cornerRadius = kAvatar / 2;
        circle.masksToBounds = YES;
        circle.backgroundColor = PXColorHex(palette[i % palette.count], 1);
        circle.borderColor = PXColorText();
        [circle addSublayer:PXAsyncLabel(initials(u[@"title"] ?: @""), PXFontHeavy(80), PXColorText(),
                                         CGRectMake(0, (kAvatar - 96) / 2, kAvatar, 96), 1, YES)];
        CALayer *photo = [CALayer layer];
        photo.frame = circle.bounds;
        photo.contentsGravity = kCAGravityResizeAspectFill;
        [circle addSublayer:photo];
        NSString *thumb = u[@"thumb"];
        if ([thumb isKindOfClass:[NSString class]] && [thumb hasPrefix:@"http"]) {
            // plex.tv itself fails TLS on iOS 8: the initials stay if the image never comes.
            [[PXImageCache shared] loadURL:[NSURL URLWithString:thumb] size:CGSizeMake(kAvatar, kAvatar) done:^(CGImageRef img) {
                if (img) { photo.contents = (__bridge id)img; PXFadeContents(photo, 0.2); }
            }];
        }
        [cell addSublayer:circle];
        NSString *name = u[@"title"] ?: @"";
        if ([u[@"protected"] boolValue]) name = [name stringByAppendingString:@" 🔒"];
        [cell addSublayer:PXAsyncLabel(name, PXFontSemi(30), PXColorText(), CGRectMake(-40, kAvatar + 24, kAvatar + 80, 40), 1, YES)];
        [self.layer addSublayer:cell];
        [_cells addObject:cell];
    }
    [self updateFocus];
}

- (void)updateFocus {
    PXAnim(0.2, ^{
        for (NSInteger i = 0; i < (NSInteger)self->_cells.count; i++) {
            CALayer *cell = self->_cells[i];
            BOOL f = i == self->_index && !self->_pinUser;
            CALayer *circle = cell.sublayers.firstObject;
            circle.borderWidth = f ? 6 : 0;
            cell.opacity = f || self->_pinUser ? 1 : 0.6;
            CGFloat k = f ? 1.1 : 1.0;
            cell.transform = CATransform3DMakeScale(k, k, 1);
        }
    });
}

#pragma mark - Choice

- (void)choose {
    if (_busy || _index >= (NSInteger)_users.count) return;
    NSDictionary *u = _users[_index];
    BOOL same = [u[@"uuid"] isEqual:[PXPlex shared].currentHomeUser[@"uuid"]];
    if (same && ![u[@"protected"] boolValue]) { [self finish]; return; }
    if ([u[@"protected"] boolValue]) { [self showPinFor:u]; return; }
    [self switchTo:u pin:nil];
}

- (void)switchTo:(NSDictionary *)u pin:(NSString *)pin {
    _busy = YES;
    _spinner = PXSpinner(60);
    _spinner.position = CGPointMake(960, 900);
    [self.layer addSublayer:_spinner];
    __weak PXProfilesScreen *weak = self;
    [[PXPlex shared] switchToHomeUser:u pin:pin done:^(id user, NSError *err) {
        PXProfilesScreen *me = weak;
        if (!me) return;
        me->_busy = NO;
        [me->_spinner removeFromSuperlayer];
        if (!user) {
            PXLog(@"profiles: switch failed: %@", err.localizedDescription);
            if (me->_pinUser) [me pinFailed:err.localizedDescription];
            return;
        }
        [me finish];
    }];
}

- (void)finish {
    void (^done)(void) = self.completion;
    [self pop];
    if (done) done();
}

#pragma mark - PIN pad

- (void)showPinFor:(NSDictionary *)u {
    _pinUser = u;
    _pin = [NSMutableString string];
    _key = 0;
    _pad = [CALayer layer];
    _pad.frame = self.layer.bounds;
    _pad.backgroundColor = PXColorBlack(0.75);
    [_pad addSublayer:PXAsyncLabel(PXLF(@"Code PIN de %@", u[@"title"] ?: @""), PXFontHeavy(56), PXColorText(), CGRectMake(0, 150, 1920, 70), 1, YES)];
    _dots = [NSMutableArray array];
    for (NSInteger i = 0; i < 4; i++) {
        CALayer *d = [CALayer layer];
        d.frame = CGRectMake(960 - 2 * 60 + i * 60 + 12, 270, 36, 36);
        d.cornerRadius = 18;
        d.borderWidth = 3;
        d.borderColor = PXColorText();
        [_pad addSublayer:d];
        [_dots addObject:d];
    }
    _pinError = PXText(PXFont(28), PXColorAccent());
    _pinError.alignmentMode = kCAAlignmentCenter;
    _pinError.frame = CGRectMake(0, 330, 1920, 40);
    [_pad addSublayer:_pinError];
    _keys = [NSMutableArray array];
    NSArray *labels = @[ @"1", @"2", @"3", @"4", @"5", @"6", @"7", @"8", @"9", @"", @"0", @"⌫" ];
    CGFloat size = 120, gap = 24, left = 960 - (3 * size + 2 * gap) / 2;
    for (NSInteger i = 0; i < 12; i++) {
        CALayer *k = [CALayer layer];
        k.frame = CGRectMake(left + (i % 3) * (size + gap), 410 + (i / 3) * (size + gap), size, size);
        k.cornerRadius = size / 2;
        k.backgroundColor = [labels[i] length] ? PXColorWhite(0.1) : [UIColor clearColor].CGColor;
        CATextLayer *t = PXText(PXFontSemi(48), PXColorText());
        t.alignmentMode = kCAAlignmentCenter;
        t.string = labels[i];
        t.frame = CGRectMake(0, (size - 60) / 2, size, 60);
        [k addSublayer:t];
        [_pad addSublayer:k];
        [_keys addObject:k];
    }
    PXNoAnim(^{ [self.layer addSublayer:self->_pad]; });
    [self updateFocus];
    [self updatePad];
}

- (void)updatePad {
    PXAnim(0.15, ^{
        for (NSInteger i = 0; i < 12; i++) {
            CALayer *k = self->_keys[i];
            BOOL f = i == self->_key;
            if (i == 9) continue;
            k.backgroundColor = f ? PXColorText() : PXColorWhite(0.1);
            [(CATextLayer *)k.sublayers.firstObject setForegroundColor:f ? PXColorBlack(0.9) : PXColorText()];
        }
        for (NSInteger i = 0; i < 4; i++)
            [self->_dots[i] setBackgroundColor:i < (NSInteger)self->_pin.length ? PXColorText() : [UIColor clearColor].CGColor];
    });
}

- (void)pressPadKey {
    if (_busy) return;
    if (_key == 11) { if (_pin.length) [_pin deleteCharactersInRange:NSMakeRange(_pin.length - 1, 1)]; }
    else if (_key != 9 && _pin.length < 4) [_pin appendString:_key == 10 ? @"0" : [@(_key + 1) stringValue]];
    PXSetText(_pinError, @"");
    [self updatePad];
    if (_pin.length == 4) [self switchTo:_pinUser pin:[_pin copy]];
}

- (void)pinFailed:(NSString *)message {
    [_pin setString:@""];
    [self updatePad];
    PXSetText(_pinError, message ?: PXL(@"Code PIN incorrect"));
    CABasicAnimation *shake = [CABasicAnimation animationWithKeyPath:@"position.x"];
    shake.byValue = @18; shake.duration = 0.06; shake.autoreverses = YES; shake.repeatCount = 3;
    for (CALayer *d in _dots) [d addAnimation:shake forKey:@"shake"];
}

- (void)closePin {
    [_pad removeFromSuperlayer];
    _pad = nil;
    _pinUser = nil;
    [self updateFocus];
}

#pragma mark - Keys

- (void)leaveApp {
    // Pop this screen and the home under it: back to the Apple TV main menu.
    id stack = [self.host stack];
    [self pop];
    dispatch_async(dispatch_get_main_queue(), ^{ if ([[stack controllers] count] > 1) [stack popController]; });
}

- (BOOL)handleKey:(PXKey)key {
    if (_pinUser) {
        NSInteger r = _key / 3, c = _key % 3;
        switch (key) {
            case PXKeyUp: if (r > 0) _key -= 3; break;
            case PXKeyDown: if (r < 3) _key += 3; break;
            case PXKeyLeft: if (c > 0) _key -= 1; break;
            case PXKeyRight: if (c < 2) _key += 1; break;
            case PXKeySelect: [self pressPadKey]; return YES;
            case PXKeyMenu: if (!_busy) [self closePin]; return YES;
            default: return NO;
        }
        if (_key == 9) _key = key == PXKeyLeft ? 10 : (key == PXKeyUp ? 6 : 10);   // empty cell
        [self updatePad];
        return YES;
    }
    switch (key) {
        case PXKeyLeft: if (_index > 0) { _index--; [self updateFocus]; } return YES;
        case PXKeyRight: if (_index + 1 < (NSInteger)_users.count) { _index++; [self updateFocus]; } return YES;
        case PXKeySelect: [self choose]; return YES;
        case PXKeyMenu: if (self.atLaunch) { [self leaveApp]; return YES; } return NO;
        default: return YES;
    }
}

@end

PXScreen *PXProfilesScreenNew(BOOL atLaunch, void (^completion)(void)) {
    PXProfilesScreen *s = [PXProfilesScreen new];
    s.atLaunch = atLaunch;
    s.completion = completion;
    [s setup];
    return s;
}
