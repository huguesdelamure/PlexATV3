// Music playback shared by the album and "now playing" screens: queue,
// shuffle, repeat, timeline reports. Keeps playing while the user browses the
// app; stops when a video starts or the app is left.

#import <Foundation/Foundation.h>
@class PXItem;

typedef NS_ENUM(NSInteger, PXRepeatMode) { PXRepeatOff, PXRepeatAll, PXRepeatOne };

extern NSString *const PXMusicDidChange;   // track, play state or queue changed

@interface PXMusicPlayer : NSObject
+ (instancetype)shared;

- (void)playTracks:(NSArray *)tracks startAt:(NSInteger)index shuffle:(BOOL)shuffle;   // PXItem tracks
- (void)togglePause;
- (void)next;
- (void)previous;       // back to the start of the track after 3 s, else previous track
- (void)stop;

@property (nonatomic, readonly) PXItem *current;
@property (nonatomic, readonly) NSArray *queue;        // in play order
@property (nonatomic, readonly) NSInteger index;
@property (nonatomic, readonly) BOOL playing;          // not paused
@property (nonatomic, readonly) BOOL active;           // a queue is loaded
@property (nonatomic, readonly) double elapsed;        // seconds
@property (nonatomic, readonly) double duration;
@property (nonatomic, assign) BOOL shuffle;            // reshuffles what follows the current track
@property (nonatomic, assign) PXRepeatMode repeat;
@property (nonatomic, assign) float volume;            // 0..1, player gain (HDMI volume is fixed)
@end
