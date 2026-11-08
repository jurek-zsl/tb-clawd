#import "ClawdMusic.h"
#import <CoreAudio/CoreAudio.h>

BOOL CWSystemAudioIsPlaying(void) {
    // kAudioObjectPropertyElementMaster is the same 0 that macOS 12 renamed to
    // ElementMain; the old name keeps the macOS 11 deployment target warning-free.
    AudioObjectPropertyAddress defaultOutput = {kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, 0};
    AudioDeviceID device = kAudioObjectUnknown;
    UInt32 size = sizeof device;
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &defaultOutput, 0, NULL, &size, &device) != noErr || device == kAudioObjectUnknown) return NO;
    AudioObjectPropertyAddress running = {kAudioDevicePropertyDeviceIsRunningSomewhere, kAudioObjectPropertyScopeGlobal, 0};
    UInt32 isRunning = 0;
    size = sizeof isRunning;
    if (AudioObjectGetPropertyData(device, &running, 0, NULL, &size, &isRunning) != noErr) return NO;
    return isRunning != 0;
}
