#import "ClawdScene.h"
#import <math.h>

static double Clamp(double x) { return fmax(0, fmin(1, x)); }
static double Ease(double x) { x = Clamp(x); return x*x*(3-2*x); }
static double Mix(double a, double b, double t) { return a+(b-a)*t; }
static double Envelope(double age, double duration, double in, double out) {
    return Ease(age/in) * Ease((duration-age)/out);
}
static void AddRect(CWScene *s, double x, double y, double w, double h, CWInk ink, BOOL actor) {
    if (s->pixelCount >= 256 || w <= 0 || h <= 0) return;
    NSRect rect = NSMakeRect(round(x), round(y), round(w), round(h));
    s->pixels[s->pixelCount++] = (CWPixel){rect, ink, actor};
    if (actor) s->actorBounds = NSIsEmptyRect(s->actorBounds) ? rect : NSUnionRect(s->actorBounds, rect);
}
static void Line(CWScene *s, double x0, double y0, double x1, double y1, int thickness, CWInk ink, BOOL actor) {
    int count = MAX(1, (int)ceil(fmax(fabs(x1-x0), fabs(y1-y0))));
    for (int i=0; i<=count; i++) AddRect(s, Mix(x0,x1,(double)i/count), Mix(y0,y1,(double)i/count), thickness, thickness, ink, actor);
}
static void Arm(CWScene *s, double sx, double sy, double ex, double ey, double wx, double wy) {
    Line(s,sx,sy,ex,ey,2,CWInkCoral,YES);
    Line(s,ex,ey,wx,wy,2,CWInkCoral,YES);
    AddRect(s,wx-1,wy-1,3,3,CWInkCoral,YES);
}
NSString *CWActivityName(CWActivity activity) {
    switch(activity) {
        case CWActivityCode:return @"coding";
        case CWActivityCoffee:return @"coffee";
        case CWActivityStretch:return @"stretching";
        case CWActivityNap:return @"napping";
        case CWActivityMad:return @"mad";
        default:return @"running";
    }
}
double CWRunDuration(CGFloat width) {
    double travel=fmax(0,width-46), acceleration=fmin(.3,travel/64);
    return fmax(.05,travel/64+acceleration);
}
double CWSceneDuration(CGFloat width) { return 4*CWRunDuration(width)+34; }

CWScene CWSampleScene(double time, CGFloat width, double reactionAge) {
    width=fmax(64,width);
    CWScene s={0};
    double run=CWRunDuration(width), duration=CWSceneDuration(width);
    const CWActivity activities[]={CWActivityRun,CWActivityCode,CWActivityRun,CWActivityCoffee,CWActivityRun,CWActivityStretch,CWActivityRun,CWActivityNap};
    double lengths[]={run,10,run,8,run,6,run,10};
    double local=fmod(fmax(0,time),duration);
    int section=0;
    while(section<7 && local>=lengths[section]) {local-=lengths[section]; section++;}
    s.activity=s.underlyingActivity=activities[section];
    s.age=local; s.duration=lengths[section]; s.baseTime=time;
    double travel=width-46;
    BOOL right=(section==0 || section==4);
    s.facingRight = s.activity==CWActivityRun ? right : (section==3 || section==7);
    double distance=0;
    if(s.activity==CWActivityRun) {
        double a=fmin(.3,travel/64);
        if(local<a) distance=32*local*local/a;
        else if(local>run-a) {double left=run-local; distance=travel-32*left*left/a;}
        else distance=64*(local-a/2);
        s.anchorX=8+(right?distance:travel-distance);
    } else s.anchorX=s.facingRight?8:width-38;
    s.travelledDistance=distance;
    double stride=travel/fmax(1,round(travel/20));
    double gait=distance/stride*2*M_PI;
    double action=s.activity==CWActivityRun ? 0 : Envelope(local,s.duration,.8,.9);
    double x=s.anchorX, bodyY=6, height=16, lean=0;
    double gaze=s.facingRight?1:-1, gazeY=0;
    BOOL blink=fmod(time+.8,4.7)<.12;
    BOOL eyesClosed=NO;
    double leftX=x, leftY=13, rightX=x+28, rightY=13;
    double leftElbowX=x, leftElbowY=15, rightElbowX=x+28, rightElbowY=15;
    double coffeeLift=0, stretch=0, reaction=0;
    if(s.activity==CWActivityRun) {
        bodyY-=round((1-cos(gait*2))*.5);
        leftY=bodyY+6+round(sin(gait)); rightY=bodyY+6-round(sin(gait));
    } else if(s.activity==CWActivityCode) {
        bodyY+=action; lean=-2*action;
        gaze=-1; gazeY=action;
        double typing=(floor(local*6) - 2*floor(local*3));
        leftX=Mix(x,x-2,action); leftY=Mix(13,24-typing,action);
        leftElbowX=x-1; leftElbowY=19;
        rightX=Mix(x+28,x+7,action); rightY=Mix(13,24-(1-typing),action);
        rightElbowX=Mix(x+28,x+25,action); rightElbowY=21;
    } else if(s.activity==CWActivityCoffee) {
        coffeeLift=Envelope(local-1.1,5.3,1.2,1.3);
        bodyY+=action; lean=action*(1+coffeeLift);
        gaze=1; gazeY=coffeeLift;
        rightX=Mix(x+28,x+31-5*coffeeLift,action);
        rightY=Mix(13,24-8*coffeeLift,action);
        rightElbowX=x+29; rightElbowY=20;
    } else if(s.activity==CWActivityStretch) {
        stretch=Envelope(local-.6,4.7,1.15,1.2);
        bodyY+=action*(1-stretch); lean=-2*stretch;
        leftX=Mix(x,x+2,stretch); leftY=Mix(13,1,stretch);
        rightX=Mix(x+28,x+26,stretch); rightY=Mix(13,1,stretch);
        leftElbowX=x-1; leftElbowY=Mix(15,7,stretch);
        rightElbowX=x+29; rightElbowY=Mix(15,7,stretch);
        eyesClosed=stretch>.7;
        gaze=0;
    } else if(s.activity==CWActivityNap) {
        double breathing=sin(local*2*M_PI/3.5);
        bodyY+=action*(5+.5*breathing); height-=action*(5+.5*breathing);
        eyesClosed=action>.5; gaze=0;
        leftX=Mix(x,x+7,action); leftY=Mix(13,bodyY+9,action);
        rightX=Mix(x+28,x+22,action); rightY=Mix(13,bodyY+9,action);
        leftElbowX=x+1; leftElbowY=bodyY+10;
        rightElbowX=x+27; rightElbowY=bodyY+10;
    }
    if(reactionAge>=0 && reactionAge<2.5) {
        s.activity=CWActivityMad;
        reaction=Envelope(reactionAge,2.5,.2,.4);
        // At the first/last pixel-sized beat preserve the exact underlying
        // silhouette, including running tabs and sleeping eyelids.
        if(reaction<.04) reaction=0;
        double shake=round(sin(reactionAge*32))*reaction;
        x+=shake;
        bodyY=Mix(bodyY,6+round(fmax(0,sin(reactionAge*18))),reaction);
        height=Mix(height,16,reaction); lean*=1-reaction;
        leftX=Mix(leftX,x+5,reaction); leftY=Mix(leftY,21,reaction);
        rightX=Mix(rightX,x+24,reaction); rightY=Mix(rightY,21,reaction);
        leftElbowX=Mix(leftElbowX,x-1,reaction); leftElbowY=Mix(leftElbowY,18,reaction);
        rightElbowX=Mix(rightElbowX,x+30,reaction); rightElbowY=Mix(rightElbowY,18,reaction);
        if(reaction>.5) eyesClosed=NO;
        gaze*=1-reaction; gazeY*=1-reaction;
    }
    // Feet remain planted during activities; the torso can lean above them.
    const double hips[]={3,8,19,24};
    for(int i=0;i<4;i++) {
        double phase=gait+(i>=2?M_PI:0);
        double swing=s.underlyingActivity==CWActivityRun?round(sin(phase)):0;
        double lift=s.underlyingActivity==CWActivityRun?round(fmax(0,cos(phase))*2):0;
        swing*=1-reaction; lift*=1-reaction;
        double hip=x+hips[i];
        AddRect(&s,hip,bodyY+height-1,3,fmax(1,26-lift-(bodyY+height-1)),CWInkCoral,YES);
        AddRect(&s,hip+swing,25-lift,3,3,CWInkCoral,YES);
    }
    for(int row=0;row<(int)round(height);row++) {
        double offset=round(lean*(1-(row+.5)/height));
        AddRect(&s,x+3+offset,bodyY+row,24,1,CWInkCoral,YES);
    }
    if(s.underlyingActivity==CWActivityRun && reaction==0) {
        AddRect(&s,x,leftY,3,6,CWInkCoral,YES); AddRect(&s,x+27,rightY,3,6,CWInkCoral,YES);
    } else {
        Arm(&s,x+3,bodyY+8,leftElbowX,leftElbowY,leftX,leftY);
        Arm(&s,x+25,bodyY+8,rightElbowX,rightElbowY,rightX,rightY);
    }
    double eyeY=bodyY+5+gazeY;
    double eyeLean=round(lean*.65);
    AddRect(&s,x+6+gaze+eyeLean,eyeY,3,eyesClosed||blink?1:3,CWInkEye,YES);
    AddRect(&s,x+21+gaze+eyeLean,eyeY,3,eyesClosed||blink?1:3,CWInkEye,YES);
    if(stretch>.55 && reaction<.5) AddRect(&s,x+14,bodyY+11,3,3,CWInkEye,YES);
    if(coffeeLift>.7 && reaction<.5) AddRect(&s,x+24,bodyY+11,2,1,CWInkEye,YES);
    if(reaction>.35) {
        Line(&s,x+6,bodyY+3,x+10,bodyY+5,1,CWInkEye,YES);
        Line(&s,x+19,bodyY+5,x+23,bodyY+3,1,CWInkEye,YES);
        AddRect(&s,x+13,bodyY+12,5,1,CWInkEye,YES);
    }
    // Props always face the bar interior and never participate in actor hits.
    if(s.underlyingActivity==CWActivityCode && action>.02) {
        double open=Envelope(local,10,.9,1.0), screenHeight=round(10*open);
        AddRect(&s,s.anchorX-20,26,23,2,CWInkLaptop,NO);
        AddRect(&s,s.anchorX-18,26-screenHeight,15,screenHeight,CWInkLaptop,NO);
        AddRect(&s,s.anchorX-17,27-screenHeight,13,fmax(0,screenHeight-2),CWInkScreen,NO);
        if(screenHeight>6) {
            int cursor=(int)floor(local*3)%3;
            AddRect(&s,s.anchorX-15,29-screenHeight,5+cursor,1,CWInkCode,NO);
            AddRect(&s,s.anchorX-15,31-screenHeight,3,1,CWInkCup,NO);
            AddRect(&s,s.anchorX-11,33-screenHeight,4,1,CWInkCode,NO);
        }
        // Fingers land on the keyboard, above the case.
        AddRect(&s,leftX-1,leftY,3,2,CWInkCoral,YES);
        AddRect(&s,rightX-1,rightY,3,2,CWInkCoral,YES);
    }
    if(s.underlyingActivity==CWActivityCoffee && action>.02) {
        double cupX=rightX+1, cupY=rightY-4;
        AddRect(&s,cupX,cupY,5,6,CWInkCup,NO);
        AddRect(&s,cupX+5,cupY+1,2,3,CWInkCup,NO);
        AddRect(&s,cupX+5,cupY+2,1,1,CWInkEye,NO);
        AddRect(&s,cupX,cupY,5,1,CWInkCoffee,NO);
        if(local>1 && local<6.7 && reaction<.3) {
            double drift=fmod(local,1.5)/1.5;
            AddRect(&s,cupX+1+round(sin(local*3)),cupY-3-3*drift,1,2,CWInkSteam,NO);
            AddRect(&s,cupX+3,cupY-5-2*drift,1,1,CWInkSteam,NO);
        }
    }
    if(s.underlyingActivity==CWActivityNap && action>.7 && reaction<.4) {
        double zX=s.anchorX+34, zY=4-round(fmod(local,2));
        AddRect(&s,zX,zY,4,1,CWInkSteam,NO); AddRect(&s,zX+2,zY+1,1,1,CWInkSteam,NO);
        AddRect(&s,zX+1,zY+2,1,1,CWInkSteam,NO); AddRect(&s,zX,zY+3,4,1,CWInkSteam,NO);
    }
    if(reaction>.4) {
        double puffX=s.facingRight?x+31:x-6, puffY=2+round(sin(reactionAge*8));
        AddRect(&s,puffX,puffY,4,2,CWInkSteam,NO); AddRect(&s,puffX+1,puffY-1,2,4,CWInkSteam,NO);
    }
    return s;
}
BOOL CWSceneHitsActor(CWScene scene, NSPoint point) {
    // Back-to-front: a visible prop in front of Clawd masks the covered pixels.
    for(NSInteger i=scene.pixelCount-1;i>=0;i--) if(NSPointInRect(point,scene.pixels[i].rect)) return scene.pixels[i].actor;
    return NO;
}
