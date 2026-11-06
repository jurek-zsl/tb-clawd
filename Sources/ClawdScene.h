#import <AppKit/AppKit.h>

typedef NS_ENUM(NSInteger, CWActivity) {
    CWActivityRun, CWActivityCode, CWActivityCoffee, CWActivityStretch, CWActivityNap, CWActivityMad
};
typedef NS_ENUM(NSInteger, CWInk) {
    CWInkCoral, CWInkEye, CWInkLaptop, CWInkScreen, CWInkCode, CWInkCup, CWInkCoffee, CWInkSteam
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

// All geometry, props, facial acting, rendering and hit testing share this sample.
CWScene CWSampleScene(double time, CGFloat width, double reactionAge);
NSString *CWActivityName(CWActivity activity);
double CWRunDuration(CGFloat width);
double CWSceneDuration(CGFloat width);
BOOL CWSceneHitsActor(CWScene scene, NSPoint point);
