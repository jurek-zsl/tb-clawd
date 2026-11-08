#import <Foundation/Foundation.h>

// YES while some app is playing sound through the default output device
// (music, a video, a call). Reads a CoreAudio property: no permission prompt,
// no audio capture, nothing about what is playing.
BOOL CWSystemAudioIsPlaying(void);
