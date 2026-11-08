#import "ClawdScene.h"
#import <math.h>

// Clawd is built on the same half-block grid as Claude Code's terminal mascot:
//
//    ▐▛███▜▌        every glyph cell is 2x2 quadrants, so the figure is an
//   ▝▜█████▛▘       18x5 grid of square "pixels": a 12 wide body, the eyes as
//     ▘▘ ▝▝         one-pixel notches cut into the body, side arms and four
//                   one-pixel legs. Poses are swapped, never tweened, which
//                   is what gives the terminal version its stepped feel.
//
// Sprite columns are numbered like the glyph (arms at 1-2 and 15-16), rows 0-4.
static const int kSpriteCols = 16;
static const int kSpriteRows = 5;

static double Clamp(double x) { return fmax(0, fmin(1, x)); }
static double Ease(double x) { x = Clamp(x); return x*x*(3-2*x); }
static double Envelope(double age, double duration, double in, double out) {
    return Ease(age/in) * Ease((duration-age)/out);
}
// Pose changes land on a few discrete beats instead of sliding.
static double Quant(double x, int levels) { return floor(Clamp(x)*levels+1e-9)/levels; }

static void AddRect(CWScene *s, double x, double y, double w, double h, CWInk ink, BOOL actor) {
    if (s->pixelCount >= 256 || w <= 0 || h <= 0) return;
    NSRect rect = NSMakeRect(round(x), round(y), round(w), round(h));
    s->pixels[s->pixelCount++] = (CWPixel){rect, ink, actor};
    if (actor) s->actorBounds = NSIsEmptyRect(s->actorBounds) ? rect : NSUnionRect(s->actorBounds, rect);
}

// A terminal cell is about twice as tall as it is wide, so each quadrant pixel
// is a tall rectangle. Match that: 3x5pt on a roomy bar, 2x4pt when squeezed.
static int PixelW(CGFloat width) { return width >= 120 ? 3 : 2; }
static int PixelH(CGFloat width) { return width >= 120 ? 5 : 4; }
static double SpritePad(void) { return 6; }
double CWAnchorMin(CGFloat width) { return SpritePad(); }
double CWAnchorMax(CGFloat width) {
    width = fmax(64, width);
    return SpritePad() + fmax(0, width - kSpriteCols*PixelW(width) - 2*SpritePad());
}

// ---------------------------------------------------------------- sprite ---

typedef NS_ENUM(int, ArmPose) { ArmDown, ArmOut, ArmUp, ArmLow, ArmCupRest, ArmCupRaised };
typedef struct { double ox, oy; int w, h; } Grid;

static void Cell(CWScene *s, Grid g, double px, double py, double w, double h, CWInk ink, BOOL actor) {
    AddRect(s, g.ox+(px-1)*g.w, g.oy+py*g.h, w*g.w, h*g.h, ink, actor);
}
// Left-arm cells per pose; the right arm mirrors them across the body.
static void Arm(CWScene *s, Grid g, ArmPose pose, BOOL right) {
    static const int cells[][3][2] = {
        [ArmDown]={{1,2},{2,2},{0,0}},
        [ArmOut]={{1,1},{2,1},{0,0}},
        [ArmUp]={{1,0},{2,0},{2,1}},
        [ArmLow]={{1,3},{2,3},{0,0}},
        [ArmCupRest]={{1,2},{2,2},{0,0}},
        [ArmCupRaised]={{1,2},{2,2},{1,1}},
    };
    for (int i=0;i<3;i++) {
        int px=cells[pose][i][0], py=cells[pose][i][1];
        if (!px) continue;
        Cell(s, g, right ? 17-px : px, py, 1, 1, CWInkCoral, YES);
    }
}
static void Spinner(CWScene *s, double x, double y, int frame);

typedef struct {
    ArmPose left, right;
    int legs;           // 0 stand, 1 spread, 2 together, -1 tucked (no legs)
    int gaze;           // -1 left, 0 centre, 1 right
    BOOL eyesClosed;    // shut eyes are a half-height notch
    BOOL scowl;         // angry brow notches
} Pose;

static void DrawSprite(CWScene *s, Grid g, Pose p) {
    Cell(s, g, 3, 0, 12, 4, CWInkCoral, YES);
    Arm(s, g, p.left, NO);
    Arm(s, g, p.right, YES);
    static const int legSets[3][4] = {{4,6,11,13},{3,5,12,14},{5,7,10,12}};
    if (p.legs >= 0) for (int i=0;i<4;i++) Cell(s, g, legSets[p.legs][i], 4, 1, 1, CWInkCoral, YES);
    const int eyes[2] = {5, 12};
    for (int i=0;i<2;i++) {
        double ex = eyes[i] + p.gaze;
        if (p.eyesClosed) {
            double half = round(g.h/2.0);
            AddRect(s, g.ox+(ex-1)*g.w, g.oy+g.h*2-half, g.w, half, CWInkEye, YES);
        } else Cell(s, g, ex, 1, 1, 1, CWInkEye, YES);
    }
    if (p.scowl) { Cell(s, g, 4, 0, 1, 1, CWInkEye, YES); Cell(s, g, 13, 0, 1, 1, CWInkEye, YES); }
}

// Claude Code's spinner: · ✢ ✳ ✶ ✻ ✽ then back again, one glyph every 120 ms.
static void Spinner(CWScene *s, double x, double y, int frame) {
    static const char *glyphs[6][8] = {
        {"........","........","........","...##...","...##...","........","........","........"},
        {"........","...##...","...##...",".######.",".######.","...##...","...##...","........"},
        {"#..##..#",".#.##.#.","..####..","########","########","..####..",".#.##.#.","#..##..#"},
        {"##....##",".##..##.","..####..","...##...","...##...","..####..",".##..##.","##....##"},
        {"##.##.##",".######.","..####..","########","########","..####..",".######.","##.##.##"},
        {"##.##.##",".######.","..####..","###..###","###..###","..####..",".######.","##.##.##"},
    };
    int sequence[10] = {0,1,2,3,4,5,4,3,2,1};
    const char **rows = glyphs[sequence[((frame%10)+10)%10]];
    for (int r=0;r<8;r++) {
        int c=0;
        while (c<8) {
            if (rows[r][c]!='#') { c++; continue; }
            int start=c; while (c<8 && rows[r][c]=='#') c++;
            AddRect(s, x+start, y+r, c-start, 1, CWInkCoral, NO);
        }
    }
}

// ------------------------------------------------------------ pixel font ---

// 3x5 glyphs for the limits readout, enough for "5H 42% 1H20".
static const char *FontGlyph(char c) {
    switch (c) {
        case '0': return "111101101101111"; case '1': return "010110010010111";
        case '2': return "111001111100111"; case '3': return "111001111001111";
        case '4': return "101101111001001"; case '5': return "111100111001111";
        case '6': return "111100111101111"; case '7': return "111001001001001";
        case '8': return "111101111101111"; case '9': return "111101111001111";
        case 'H': return "101101111101101"; case 'D': return "110101101101110";
        case 'M': return "101111111101101"; case '%': return "101001010100101";
        case '-': return "000000111000000"; case '?': return "111001011000010";
        case '.': return "000000000000010";
        case 'E': return "111100111100111"; case 'X': return "101101010101101";
        case 'P': return "111101111100100"; case 'I': return "111010010010111";
        case 'R': return "110101110101101"; case 'N': return "111101101101101";
        case 'O': return "111101101101111"; case 'L': return "100100100100111";
        case 'G': return "111100101101111"; case 'F': return "111100111100100";
        case 'C': return "111100100100111"; case 'A': return "010101111101101";
        case 'T': return "111010010010010"; case 'U': return "101101101101111";
        case 'S': return "111100111001111";
        default: return "000000000000000";
    }
}
static double TextWidth(const char *text, int p) { return strlen(text) ? strlen(text)*4*p-p : 0; }
static void Text(CWScene *s, double x, double y, const char *text, int p, CWInk ink) {
    for (size_t i=0; text[i]; i++, x+=4*p) {
        const char *g=FontGlyph(text[i]);
        for (int r=0;r<5;r++) {
            int c=0;
            while (c<3) {
                if (g[r*3+c]!='1') { c++; continue; }
                int start=c; while (c<3 && g[r*3+c]=='1') c++;
                AddRect(s, x+start*p, y+r*p, (c-start)*p, p, ink, NO);
            }
        }
    }
}
static void ResetText(char *out, size_t size, CWLimitWindow w) {
    long minutes=(long)ceil(fmax(0,w.resetsIn)/60);
    if (!w.known || w.resetsIn<=0) out[0]=0;
    else if (minutes<60) snprintf(out,size,"%ldM",minutes);
    else if (minutes<10*60) snprintf(out,size,"%ldH%02ld",minutes/60,minutes%60);
    else if (minutes<48*60) snprintf(out,size,"%ldH",minutes/60);
    else snprintf(out,size,"%ldD",minutes/(24*60));
}
static double LimitsRowWidth(int p, BOOL withReset) {
    // label, bar, percent, reset: "5H" [bar] "100%" "1H20"
    return TextWidth("5H",p) + 2*p + 12*p + 2*p + TextWidth("100%",p) + (withReset ? 3*p + TextWidth("1H20",p) : 0);
}
static void LimitsRow(CWScene *s, double x, double y, int p, BOOL withReset, const char *label, CWLimitWindow w) {
    Text(s, x, y, label, p, CWInkText);
    x += TextWidth(label,p) + 2*p;
    double barW=12*p;
    AddRect(s, x, y+p, barW, 3*p, CWInkTrack, NO);
    double left = w.known ? fmax(0, fmin(100, 100-w.usedPercent)) : 0;
    CWInk ink = left>50 ? CWInkCode : (left>20 ? CWInkWarn : CWInkLow);
    if (w.known && left>0) AddRect(s, x, y+p, fmax(p, round(barW*left/100)), 3*p, ink, NO);
    x += barW + 2*p;
    char text[16];
    if (w.known) snprintf(text,sizeof text,"%d%%",(int)round(left)); else snprintf(text,sizeof text,"--");
    Text(s, x, y, text, p, w.known ? ink : CWInkText);
    if (withReset) {
        x += TextWidth("100%",p) + 3*p;
        char reset[16]; ResetText(reset,sizeof reset,w);
        Text(s, x, y, reset, p, CWInkSteam);
    }
}

// ----------------------------------------------------------------- scene ---

NSString *CWActivityName(CWActivity activity) {
    switch(activity) {
        case CWActivityCode:return @"coding";
        case CWActivityCoffee:return @"coffee";
        case CWActivityStretch:return @"stretching";
        case CWActivityNap:return @"napping";
        case CWActivityMad:return @"mad";
        case CWActivityWave:return @"waving";
        case CWActivityLimits:return @"limits";
        case CWActivityDance:return @"dancing";
        case CWActivityServer:return @"server";
        case CWActivityBug:return @"bug";
        case CWActivityDuck:return @"duck";
        default:return @"running";
    }
}
double CWRunTime(double travel) {
    travel=fmax(0,travel);
    return fmax(.05,travel/64+fmin(.3,travel/64));
}
double CWRunDistance(double local, double travel) {
    double run=CWRunTime(travel), a=fmin(.3,travel/64);
    if(travel<=0) return 0;
    local=fmax(0,fmin(run,local));
    if(local<a) return 32*local*local/a;
    if(local>run-a) {double left=run-local; return travel-32*left*left/a;}
    return 64*(local-a/2);
}
double CWRunDuration(CGFloat width) { return CWRunTime(CWAnchorMax(width)-CWAnchorMin(width)); }
double CWSceneDuration(CGFloat width) { return 4*CWRunDuration(width)+34; }

CWBeat CWTimelineBeat(double time, CGFloat width) { return CWTimelineBeatMusic(time,width,NO); }

CWBeat CWTimelineBeatMusic(double time, CGFloat width, BOOL music) {
    width=fmax(64,width);
    CWBeat b={0};
    double run=CWRunDuration(width), duration=CWSceneDuration(width);
    const CWActivity activities[]={CWActivityRun,CWActivityCode,CWActivityRun,CWActivityCoffee,CWActivityRun,
        music?CWActivityDance:CWActivityStretch,CWActivityRun,music?CWActivityDance:CWActivityNap};
    double lengths[]={run,10,run,8,run,6,run,10};
    double local=fmod(fmax(0,time),duration);
    int section=0;
    while(section<7 && local>=lengths[section]) {local-=lengths[section]; section++;}
    b.activity=activities[section];
    b.age=local; b.duration=lengths[section]; b.clock=time;
    double minX=CWAnchorMin(width), maxX=CWAnchorMax(width), travel=maxX-minX;
    BOOL right=(section==0 || section==4);
    b.facingRight = b.activity==CWActivityRun ? right : (section==3 || section==7);
    if(b.activity==CWActivityRun) {
        b.distance=CWRunDistance(local,travel);
        b.anchorX=right?minX+b.distance:maxX-b.distance;
    } else b.anchorX=b.facingRight?minX:maxX;
    return b;
}

// ----------------------------------------------------------------- props ---

// An eighth note, 6x7.
static void Note(CWScene *s, double x, double y) {
    AddRect(s,x+2,y,1,6,CWInkNote,NO);
    AddRect(s,x+3,y,2,1,CWInkNote,NO);
    AddRect(s,x+4,y+1,1,2,CWInkNote,NO);
    AddRect(s,x,y+5,3,2,CWInkNote,NO);
}

// A rack of three units that builds up from the floor. While it is broken
// (before the fix) the middle unit is pulled out and blinks red; once fixed
// every light is green.
static const double kServerFixedAt = 7;
static void ServerRack(CWScene *s, double rx, double bottom, int pw, int ph, double open, double local) {
    double height=5*ph, width=7*pw, shown=round(height*open);
    if(shown<=0) return;
    AddRect(s,rx,bottom-shown,width,shown,CWInkLaptop,NO);
    if(open<1) return;
    double top=bottom-height, slot=floor((height-4)/3), unit=slot-1;
    BOOL fixed=local>=kServerFixedAt;
    for(int i=0;i<3;i++) {
        double y=top+2+i*slot, pull=(i==1 && !fixed && local>1.2)?-3:0;
        CWInk led=CWInkCode;
        if(i==1 && !fixed) led=fmod(local,.6)<.3?CWInkLow:CWInkTrack;
        else if(i==0 && fmod(local+.4,2.2)<.2) led=CWInkWarn;
        AddRect(s,rx+2+pull,y,width-4,unit,CWInkScreen,NO);
        AddRect(s,rx+3+pull,y+floor((unit-2)/2),2,2,led,NO);
        AddRect(s,rx+7+pull,y+floor(unit/2),width-11,1,CWInkLaptop,NO);
    }
}

// A beetle walking left, two leg frames.
static void Bug(CWScene *s, double x, int frame) {
    AddRect(s,x+1,23,4,3,CWInkLow,NO);
    AddRect(s,x,24,1,2,CWInkLow,NO);
    AddRect(s,x-1,23,1,1,CWInkLow,NO);
    AddRect(s,x+(frame?1:2),26,1,1,CWInkLow,NO);
    AddRect(s,x+(frame?3:4),26,1,1,CWInkLow,NO);
}
static void Splat(CWScene *s, double x) {
    AddRect(s,x-1,25,8,2,CWInkLow,NO);
    AddRect(s,x,24,1,1,CWInkLow,NO);
    AddRect(s,x+5,24,1,1,CWInkLow,NO);
    AddRect(s,x+2,26,1,1,CWInkEye,NO);
}

// A rubber duck facing left, 8u wide and 5u tall.
static void Duck(CWScene *s, double x, int u, int nod) {
    double floorY=27;
    AddRect(s,x+u,floorY-3*u,5*u,3*u,CWInkDuck,NO);
    AddRect(s,x+6*u,floorY-4*u,u,u,CWInkDuck,NO);
    AddRect(s,x,floorY-5*u+nod,3*u,3*u,CWInkDuck,NO);
    AddRect(s,x-u,floorY-4*u+nod,u,u,CWInkCoral,NO);
    AddRect(s,x+u,floorY-4*u+nod,1,1,CWInkEye,NO);
}

// A speech bubble with up to three dots, or the idea that follows.
static void Bubble(CWScene *s, double x, int dots) {
    AddRect(s,x,3,15,9,CWInkText,NO);
    AddRect(s,x,12,2,2,CWInkText,NO);
    for(int i=0;i<dots;i++) AddRect(s,x+3+i*4,6,2,2,CWInkEye,NO);
}
static void Idea(CWScene *s, double x, BOOL rays) {
    static const char *rows[7]={"..###..",".#####.",".#####.",".#####.","..###..","..###..","...#..."};
    for(int r=0;r<7;r++) {
        int c=0;
        while(c<7) {
            if(rows[r][c]!='#') {c++; continue;}
            int start=c; while(c<7 && rows[r][c]=='#') c++;
            AddRect(s,x+start,5+r,c-start,1,r>=5?CWInkLaptop:CWInkWarn,NO);
        }
    }
    if(rays) {
        AddRect(s,x-3,7,2,1,CWInkWarn,NO); AddRect(s,x+8,7,2,1,CWInkWarn,NO);
        AddRect(s,x+3,2,1,2,CWInkWarn,NO);
    }
}

// ------------------------------------------------------------ work loop ---

// Four stations along the bar. Clawd starts at the laptop on the right, then
// visits the server rack at the left end, the bug a third of the way across
// and the rubber duck two thirds across, and runs back to the laptop.
enum { kWorkStations = 4 };
static void WorkStations(CGFloat width, double x[kWorkStations], CWActivity activity[kWorkStations], double length[kWorkStations], BOOL right[kWorkStations]) {
    double minX=CWAnchorMin(width), maxX=CWAnchorMax(width), travel=maxX-minX;
    double xs[]={maxX,minX,minX+.35*travel,minX+.7*travel};
    CWActivity as[]={CWActivityCode,CWActivityServer,CWActivityBug,CWActivityDuck};
    double ls[]={14,10,9,8};
    BOOL rs[]={NO,YES,YES,YES};
    for(int i=0;i<kWorkStations;i++) {x[i]=xs[i]; activity[i]=as[i]; length[i]=ls[i]; right[i]=rs[i];}
}
double CWWorkDuration(CGFloat width) {
    width=fmax(64,width);
    double x[kWorkStations], length[kWorkStations]; CWActivity activity[kWorkStations]; BOOL right[kWorkStations];
    WorkStations(width,x,activity,length,right);
    double total=0;
    for(int i=0;i<kWorkStations;i++) total+=length[i]+CWRunTime(fabs(x[i]-x[(i+1)%kWorkStations]));
    return total;
}
CWBeat CWWorkBeat(double time, CGFloat width) {
    width=fmax(64,width);
    double x[kWorkStations], length[kWorkStations]; CWActivity activity[kWorkStations]; BOOL right[kWorkStations];
    WorkStations(width,x,activity,length,right);
    double local=fmod(fmax(0,time),CWWorkDuration(width));
    CWBeat b={0};
    b.clock=time;
    for(int i=0;i<kWorkStations;i++) {
        if(local<length[i]) {
            b.activity=activity[i]; b.age=local; b.duration=length[i];
            b.anchorX=x[i]; b.facingRight=right[i];
            return b;
        }
        local-=length[i];
        double from=x[i], to=x[(i+1)%kWorkStations], travel=fabs(to-from), run=CWRunTime(travel);
        if(local<run) {
            double distance=CWRunDistance(local,travel);
            b.activity=CWActivityRun; b.age=local; b.duration=run; b.distance=distance;
            b.facingRight=to>from;
            b.anchorX=b.facingRight?from+distance:from-distance;
            return b;
        }
        local-=run;
    }
    b.activity=CWActivityCode; b.duration=length[0]; b.anchorX=x[0];
    return b;
}

CWScene CWSampleScene(double time, CGFloat width, double reactionAge) {
    return CWRenderBeat(CWTimelineBeat(time,width), width, CWActivityMad, reactionAge, NULL);
}

CWScene CWRenderBeat(CWBeat beat, CGFloat width, CWActivity reactionKind, double reactionAge, const CWLimits *limits) {
    width=fmax(64,width);
    CWScene s={0};
    const int pw=PixelW(width), ph=PixelH(width);
    const double spriteW=kSpriteCols*pw, groundTop=27-kSpriteRows*ph;
    double local=beat.age, time=beat.clock, distance=beat.distance;
    s.activity=s.underlyingActivity=beat.activity;
    s.age=local; s.duration=beat.duration; s.baseTime=time;
    s.facingRight=beat.facingRight;
    s.anchorX=fmax(CWAnchorMin(width),fmin(CWAnchorMax(width),beat.anchorX));
    s.travelledDistance=distance;
    double action=s.activity==CWActivityRun ? 0 : Quant(Envelope(local,s.duration,.8,.9),3);

    Pose pose={ArmDown,ArmDown,0,s.facingRight?1:-1,NO,NO};
    double x=s.anchorX, bob=0;
    double lift=0, stretch=0;
    BOOL blink=fmod(time+.8,4.7)<.14;

    if(s.activity==CWActivityRun) {
        // Four-beat gait: spread, stand, together, stand. The torso hops on the
        // standing beats and the arms pump with it.
        int step=((int)floor(distance/7))&3;
        const int legBeats[4]={1,0,2,0};
        pose.legs=legBeats[step];
        if(step&1) bob=-floor(ph/2.0);
        pose.left=pose.right=(step&1)?ArmDown:ArmOut;
        if(distance<=0) {pose.left=pose.right=ArmDown;}
    } else if(s.activity==CWActivityCode) {
        // Clawd turns to the screen, eyes on it, and types on alternating beats.
        pose.gaze=action>0?-1:(fmod(local,1.6)<.8?-1:1);
        if(action>0) {
            int tap=((int)floor(local*6))&1;
            pose.left=tap?ArmLow:ArmDown;
            pose.right=tap?ArmDown:ArmLow;
        }
    } else if(s.activity==CWActivityCoffee) {
        lift=Quant(Envelope(local-1.1,5.3,1.2,1.3),2)*(action>0?1:0);
        pose.right=lift>0?ArmCupRaised:ArmCupRest;
        pose.eyesClosed=lift>=1;
    } else if(s.activity==CWActivityStretch) {
        // Arms out, arms up with a held yawn, then back down.
        stretch=Quant(Envelope(local-.6,4.7,1.15,1.2),2)*(action>0?1:0);
        pose.gaze=0;
        pose.left=pose.right=stretch>=1?ArmUp:(stretch>0?ArmOut:ArmDown);
        if(stretch>=1) {bob=-floor(ph/2.0); pose.eyesClosed=YES;}
    } else if(s.activity==CWActivityNap) {
        // Curl up: drop onto the legs, close the eyes, breathe in slow steps.
        pose.gaze=0;
        if(action>=2.0/3) {
            pose.legs=-1; pose.eyesClosed=YES;
            bob=ph+(fmod(local,3.5)<1.75?0:floor(ph/2.0));
        } else if(action>0) bob=floor(ph/2.0);
    } else if(s.activity==CWActivityWave) {
        // Waiting for you: face the user and wave one arm, then the other.
        pose.gaze=0;
        if(action>0) {
            int wave=((int)floor(local*3))&3;
            pose.left=wave==0?ArmUp:(wave==1?ArmOut:ArmDown);
            pose.right=wave==2?ArmUp:(wave==3?ArmOut:ArmDown);
        }
    } else if(s.activity==CWActivityDance) {
        // Music: arms and legs swap on every quarter second, hopping on the
        // off-beats and swaying side to side, eyes shut every fourth step.
        pose.gaze=0;
        if(action>0) {
            static const ArmPose lefts[8]={ArmUp,ArmOut,ArmDown,ArmOut,ArmUp,ArmLow,ArmUp,ArmOut};
            static const ArmPose rights[8]={ArmDown,ArmOut,ArmUp,ArmOut,ArmUp,ArmLow,ArmUp,ArmOut};
            static const int legs[8]={1,0,2,0,1,0,2,0};
            int beat=((int)floor(local*4))&7;
            pose.left=lefts[beat]; pose.right=rights[beat]; pose.legs=legs[beat];
            if(beat&1) bob=-floor(ph/2.0);
            x+=((beat>>1)&1)?pw:-pw;
            pose.eyesClosed=(beat&3)==2;
        }
    } else if(s.activity==CWActivityServer) {
        // Facing the rack: the right arm turns a wrench, then both arms go up
        // in a hop once every light is green.
        if(action>0) {
            if(local<kServerFixedAt) pose.right=(((int)floor(local*4))&1)?ArmUp:ArmOut;
            else {
                pose.left=pose.right=ArmUp; pose.eyesClosed=YES;
                if(((int)floor(local*4))&1) bob=-floor(ph/2.0);
            }
        }
    } else if(s.activity==CWActivityBug) {
        // A bug walks up. Clawd winds up with both arms and a frown, then
        // lunges and stomps it flat. Two bugs per nine seconds.
        if(action>0) {
            double cycle=fmod(local,4.5);
            if(cycle>=2.0 && cycle<2.5) {pose.left=pose.right=ArmUp; pose.scowl=YES;}
            else if(cycle>=2.5 && cycle<3.2) {
                pose.left=pose.right=ArmLow; pose.legs=2; pose.scowl=YES;
                bob=floor(ph/2.0); x+=pw;
            }
        }
    } else if(s.activity==CWActivityDuck) {
        // Explaining the problem to a rubber duck, hands moving, until the
        // idea lands.
        if(action>0) {
            if(local<5.4) pose.right=(((int)floor(local*2))&1)?ArmOut:ArmDown;
            else {
                pose.left=pose.right=ArmUp; pose.eyesClosed=YES;
                if(((int)floor(local*4))&1) bob=-floor(ph/2.0);
            }
        }
    }
    if(!pose.eyesClosed && blink) pose.eyesClosed=YES;

    // Reactions: the mad tantrum (autonomous) or the limits readout (live).
    double reaction=0, shake=0;
    BOOL showLimits=NO;
    double panelX=0, panelW=0; int fontPx=1; BOOL withReset=NO, hideActor=NO, panelRight=YES;
    if(reactionAge>=0 && reactionKind==CWActivityMad && reactionAge<2.5) {
        s.activity=CWActivityMad;
        reaction=Envelope(reactionAge,2.5,.2,.4);
        x=s.anchorX;
        // The first/last beat keeps the exact underlying silhouette.
        if(reaction<.04) reaction=0;
        if(reaction>0) {
            shake=round(sin(reactionAge*32))*1;
            x+=shake;
            bob=-(fmax(0,sin(reactionAge*18))>.5?1:0)*floor(ph/2.0);
            pose=(Pose){ArmUp,ArmUp,0,0,NO,YES};
        }
    } else if(reactionAge>=0 && reactionKind==CWActivityLimits && reactionAge<4) {
        s.activity=CWActivityLimits;
        showLimits=YES;
        x=s.anchorX;
        // Put the panel on the roomier side of Clawd at the largest size that fits.
        double leftRoom=x-2, rightRoom=width-(x+spriteW)-2;
        BOOL onRight=rightRoom>=leftRoom;
        panelRight=onRight;
        double room=fmax(leftRoom,rightRoom)-4;
        const struct {int p; BOOL reset;} sizes[]={{2,YES},{2,NO},{1,YES},{1,NO}};
        int pick=-1;
        for(int i=0;i<4;i++) if(LimitsRowWidth(sizes[i].p,sizes[i].reset)<=room) {pick=i; break;}
        if(pick<0) {
            // Too narrow to share: the readout takes the whole strip.
            hideActor=YES;
            for(int i=0;i<4;i++) if(LimitsRowWidth(sizes[i].p,sizes[i].reset)<=width-4) {pick=i; break;}
            if(pick<0) pick=3;
            fontPx=sizes[pick].p; withReset=sizes[pick].reset;
            panelW=LimitsRowWidth(fontPx,withReset);
            panelX=round((width-panelW)/2);
        } else {
            fontPx=sizes[pick].p; withReset=sizes[pick].reset;
            panelW=LimitsRowWidth(fontPx,withReset);
            panelX=onRight ? x+spriteW+4 : x-4-panelW;
        }
        // Clawd presents the numbers: arms out, looking at the panel.
        pose=(Pose){ArmOut,ArmOut,0,onRight?1:-1,NO,NO};
        bob=0;
        if(reactionAge<.12 || reactionAge>3.88) pose.left=pose.right=ArmDown;
    }

    // Props face the bar interior and never participate in actor hits; Clawd
    // puts them down while he presents the limits readout. The
    // laptop is drawn first so Clawd stands in front of it and both typing
    // hands stay visible over the keyboard.
    if(s.underlyingActivity==CWActivityCode && action>0 && !showLimits) {
        double open=Quant(Envelope(local,s.duration,.9,1.0),3);
        double base=groundTop+4*ph, screenHeight=round(2*ph*open);
        double lx=fmax(0,s.anchorX-5*pw), lw=9*pw;
        AddRect(&s,lx,base,lw,ph,CWInkLaptop,NO);
        if(screenHeight>0) {
            AddRect(&s,lx+pw,base-screenHeight,6*pw,screenHeight,CWInkLaptop,NO);
            AddRect(&s,lx+pw+1,base-screenHeight+1,6*pw-2,fmax(0,screenHeight-1),CWInkScreen,NO);
        }
        if(open>=1) {
            int cursor=((int)floor(local*3))%3;
            double cx=lx+pw+3, top=base-screenHeight+2;
            AddRect(&s,cx,top,3+cursor,1,CWInkCode,NO);
            AddRect(&s,cx,top+2,3,1,CWInkCup,NO);
            AddRect(&s,cx+4,top+5,4,1,CWInkCode,NO);
            // Thinking: Claude Code's spinner ticks above the screen.
            Spinner(&s,lx+pw+2,1,(int)floor(local/0.12));
        }
    }
    BOOL propsUp=action>0 && !showLimits;
    if(s.underlyingActivity==CWActivityServer && propsUp) {
        double rx=fmin(s.anchorX+spriteW+pw+1,width-7*pw);
        ServerRack(&s,rx,groundTop+5*ph,pw,ph,Quant(Envelope(local,s.duration,.9,1.0),3),local);
    }
    if(s.underlyingActivity==CWActivityBug && propsUp) {
        // The bug crawls in from the right in eight steps, stops in front of
        // Clawd while he winds up, and stays squashed until the next one.
        double cycle=fmod(local,4.5), stop=s.anchorX+spriteW+2*pw;
        double start=fmax(stop,fmin(stop+5*pw+4,width-7));
        if(cycle<2.5) Bug(&s,start-(start-stop)*Quant(cycle/2.0,8),((int)floor(cycle*8))&1);
        else if(cycle<4.2) Splat(&s,stop);
    }
    if(s.underlyingActivity==CWActivityDuck && propsUp) {
        int u=pw>=3?2:1;
        double duckX=fmin(s.anchorX+spriteW+3*pw+u,width-7*u-1);
        Duck(&s,duckX,u,(local<5.4 && fmod(local,2.4)>2.0)?1:0);
    }
    if(!hideActor) {
        Grid g={x, groundTop+bob, pw, ph};
        DrawSprite(&s, g, pose);
    }
    if(s.underlyingActivity==CWActivityCoffee && action>0 && !showLimits) {
        double cupW=pw+2, cupH=ph+2;
        double cupX=x+(lift>=1?13:(lift>0?15:16))*pw, cupY=groundTop+bob+(lift>0?ph:2*ph)-1;
        AddRect(&s,cupX,cupY,cupW,cupH,CWInkCup,NO);
        AddRect(&s,cupX+cupW,cupY+1,2,cupH-3,CWInkCup,NO);
        AddRect(&s,cupX+cupW,cupY+2,1,fmax(1,cupH-5),CWInkEye,NO);
        AddRect(&s,cupX,cupY,cupW,1,CWInkCoffee,NO);
        if(local>1 && local<6.7 && reaction==0 && !showLimits) {
            int step=((int)floor(local/0.3))%4;
            AddRect(&s,cupX+1+(step&1),fmax(2,cupY-3-step%2*2),1,2,CWInkSteam,NO);
            AddRect(&s,cupX+cupW-2-(step&1),fmax(0,cupY-6-step/2),1,1,CWInkSteam,NO);
        }
    }
    if(s.underlyingActivity==CWActivityNap && action>=1 && reaction==0 && !showLimits) {
        int step=((int)floor(local*1.2))%3;
        double zX=fmin(width-9,x+spriteW+3+step*2), zY=6-step*2;
        AddRect(&s,zX,zY,4,1,CWInkSteam,NO); AddRect(&s,zX+2,zY+1,1,1,CWInkSteam,NO);
        AddRect(&s,zX+1,zY+2,1,1,CWInkSteam,NO); AddRect(&s,zX,zY+3,4,1,CWInkSteam,NO);
    }
    if(s.underlyingActivity==CWActivityWave && action>0 && !showLimits && ((int)floor(local*2)&1)==0) {
        // A blinking "!" on the interior side: Claude needs an answer.
        double bx=s.facingRight?fmin(width-4,x+spriteW+3):fmax(0,x-5);
        AddRect(&s,bx,4,2,9,CWInkWarn,NO);
        AddRect(&s,bx,15,2,2,CWInkWarn,NO);
    }
    if(s.underlyingActivity==CWActivityDance && propsUp && reaction==0) {
        // Notes drift up on both sides, two pixels at a time.
        for(int i=0;i<2;i++) {
            double t=local*3+i*3;
            int step=((int)floor(t))%6;
            double nx=i==0?fmin(width-7,x+spriteW+3+(step&1)):fmax(0,x-8-(step&1));
            Note(&s,nx,17-step*2.5);
        }
    }
    if(s.underlyingActivity==CWActivityServer && propsUp && reaction==0) {
        // The wrench: handle from the arm tip to the rack, jaw on the bolt.
        int turn=((int)floor(local*4))&1;
        if(local<kServerFixedAt) {
            double ty=groundTop+bob+(turn?0:ph)+floor(ph/2.0), jx=s.anchorX+spriteW+pw+2;
            AddRect(&s,s.anchorX+spriteW,ty-1,pw+3,2,CWInkText,NO);
            AddRect(&s,jx,ty-3,2,6,CWInkText,NO);
            if(turn) {AddRect(&s,jx-3,fmax(0,ty-5),1,1,CWInkWarn,NO); AddRect(&s,jx-1,ty+4,1,1,CWInkWarn,NO);}
        }
    }
    if(s.underlyingActivity==CWActivityDuck && propsUp && reaction==0) {
        double bx=fmin(s.anchorX+spriteW+2*pw,width-16);
        if(local<5.4) {
            if(local>.6) Bubble(&s,bx,1+((int)floor(local*2.5))%3);
        } else Idea(&s,fmin(bx+4,width-10),((int)floor(local*5))&1);
    }
    if(reaction>0) {
        // A stepped puff of steam beside whichever side Clawd faces.
        double puffX=s.facingRight?fmin(width-6,x+spriteW+2):fmax(0,x-6), puffY=2+((int)floor(reactionAge*6)&1)*2;
        AddRect(&s,puffX,puffY,4,2,CWInkSteam,NO); AddRect(&s,puffX+1,puffY-1,2,4,CWInkSteam,NO);
    }
    if(showLimits) {
        CWLimits none={0};
        const CWLimits *l=limits?limits:&none;
        int p=fontPx;
        double rowH=5*p, gap=fontPx==2?4:3, top=round((30-2*rowH-gap)/2);
        if(!l->available) {
            // Still asking: three dots, one lit and raised at a time. No old
            // numbers stand in for the real ones. Otherwise no data ("?").
            if(l->loading) {
                int lit=((int)floor(reactionAge*4))%3, size=2*p, gap=2*p;
                double total=3*size+2*gap, dotsY=round((30-size)/2);
                // Beside Clawd on the side the panel is on; centred when it has the strip to itself.
                double dotsX=hideActor?panelX+round((panelW-total)/2):(panelRight?panelX+2*p:panelX+panelW-total-2*p);
                for(int i=0;i<3;i++) AddRect(&s,dotsX+i*(size+gap),dotsY-(i==lit?p:0),size,size,i==lit?CWInkText:CWInkSteam,NO);
            } else Text(&s,panelX,round((30-rowH)/2),l->note[0]?l->note:"?",p,l->note[0]?CWInkWarn:CWInkText);
        } else {
            LimitsRow(&s,panelX,top,p,withReset,"5H",l->fiveHour);
            LimitsRow(&s,panelX,top+rowH+gap,p,withReset,"7D",l->sevenDay);
        }
        // A hidden actor still answers taps over its usual span.
        if(hideActor) s.actorBounds=NSMakeRect(x,groundTop,spriteW,5*ph);
    }
    return s;
}
BOOL CWSceneHitsActor(CWScene scene, NSPoint point) {
    // Back-to-front: a visible prop in front of Clawd masks the covered pixels.
    for(NSInteger i=scene.pixelCount-1;i>=0;i--) if(NSPointInRect(point,scene.pixels[i].rect)) return scene.pixels[i].actor;
    return NO;
}
