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

CWBeat CWTimelineBeat(double time, CGFloat width) {
    width=fmax(64,width);
    CWBeat b={0};
    double run=CWRunDuration(width), duration=CWSceneDuration(width);
    const CWActivity activities[]={CWActivityRun,CWActivityCode,CWActivityRun,CWActivityCoffee,CWActivityRun,CWActivityStretch,CWActivityRun,CWActivityNap};
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
    }
    if(!pose.eyesClosed && blink) pose.eyesClosed=YES;

    // Reactions: the mad tantrum (autonomous) or the limits readout (live).
    double reaction=0, shake=0;
    BOOL showLimits=NO;
    double panelX=0, panelW=0; int fontPx=1; BOOL withReset=NO, hideActor=NO;
    if(reactionAge>=0 && reactionKind==CWActivityMad && reactionAge<2.5) {
        s.activity=CWActivityMad;
        reaction=Envelope(reactionAge,2.5,.2,.4);
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
        // Put the panel on the roomier side of Clawd at the largest size that fits.
        double leftRoom=x-2, rightRoom=width-(x+spriteW)-2;
        BOOL onRight=rightRoom>=leftRoom;
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
            // Still asking ("..." stepping in), or no data to show ("?").
            if(l->loading) {
                char dots[4]={0}; int n=1+((int)floor(reactionAge*4))%3;
                for(int i=0;i<n;i++) dots[i]='.';
                Text(&s,panelX,round((30-rowH)/2),dots,p,CWInkText);
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
