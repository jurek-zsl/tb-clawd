#import <AppKit/AppKit.h>

typedef NS_ENUM(NSInteger, CWActivity) {
    CWActivityRun, CWActivityCode, CWActivityCoffee, CWActivityStretch, CWActivityNap,
    CWActivityMad,      // tap reaction in the autonomous widget
    CWActivityWave,     // live widget: Claude is waiting for you
    CWActivityLimits,   // live widget: tap shows remaining usage limits
    CWActivityDance,    // autonomous widget: music is playing
    CWActivityServer,   // live widget, Claude working: fixing the server rack
    CWActivityBug,      // live widget, Claude working: stomping a bug
    CWActivityDuck      // live widget, Claude working: rubber duck debugging
};
typedef NS_ENUM(NSInteger, CWInk) {
    CWInkCoral, CWInkEye, CWInkLaptop, CWInkScreen, CWInkCode, CWInkCup, CWInkCoffee, CWInkSteam,
    CWInkText, CWInkTrack, CWInkWarn, CWInkLow, CWInkNote, CWInkDuck
};
typedef struct { NSRect rect; CWInk ink; BOOL actor; } CWPixel;
typedef struct {
    CWActivity activity;
    CWActivity underlyingActivity;
    double age, duration, baseTime, anchorX, travelledDistance;
    BOOL facingRight;
    NSRect actorBounds;
    NSInteger pixelCount;
    CWPixel pixels[256];
} CWScene;

// One moment of Clawd's acting, independent of what decided it: the autonomous
// loop or the live Claude Code director both produce beats.
typedef struct {
    CWActivity activity;
    double age, duration;   // duration may be INFINITY for an open-ended hold
    double anchorX, distance, clock;
    BOOL facingRight;
} CWBeat;

// A usage window from Claude Code's status line `rate_limits` payload.
typedef struct { BOOL known; double usedPercent; double resetsIn; } CWLimitWindow;
// `note` is a short word for why there are no numbers ("EXPIRED", "OFFLINE"...);
// empty means no reason is known.
typedef struct { BOOL available, loading; CWLimitWindow fiveHour, sevenDay; char note[12]; } CWLimits;

// All geometry, props, facial acting, rendering and hit testing share this sample.
CWScene CWSampleScene(double time, CGFloat width, double reactionAge);
CWBeat CWTimelineBeat(double time, CGFloat width);
// The same loop with music playing: stretching and napping become dancing, so
// the schedule keeps every length and anchor and toggling music never jumps.
CWBeat CWTimelineBeatMusic(double time, CGFloat width, BOOL music);
// What live Clawd does while Claude works: laptop, server rack, bug and rubber
// duck stations with runs in between. Starts at the laptop.
CWBeat CWWorkBeat(double time, CGFloat width);
double CWWorkDuration(CGFloat width);
// reaction is CWActivityMad, CWActivityLimits, or -1 for none.
CWScene CWRenderBeat(CWBeat beat, CGFloat width, CWActivity reaction, double reactionAge, const CWLimits *limits);
double CWRunDistance(double local, double travel);
double CWRunTime(double travel);
NSString *CWActivityName(CWActivity activity);
double CWAnchorMin(CGFloat width);
double CWAnchorMax(CGFloat width);
double CWRunDuration(CGFloat width);
double CWSceneDuration(CGFloat width);
BOOL CWSceneHitsActor(CWScene scene, NSPoint point);
