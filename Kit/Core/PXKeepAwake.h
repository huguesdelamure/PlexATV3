// Keeps the Apple TV awake during playback: no screensaver over a video, no
// idle sleep during video or music (BackRow does it for its own players only).

#import <Foundation/Foundation.h>

// Call regularly while playing (cheap, throttled inside). video: also holds
// off the screensaver; music lets it run like the stock music player.
void PXKeepAwake(BOOL video);
// Playback stopped or paused: the device may sleep again.
void PXAllowSleep(void);
