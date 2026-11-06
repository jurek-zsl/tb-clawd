#import <AppKit/AppKit.h>
#import "ClawdScene.h"

// What local Claude Code is doing, from ~/.claude/sessions/<pid>.json.
typedef NS_ENUM(NSInteger, CWLiveState) {
    CWLiveAsleep,   // no live session, or every session idle for a while
    CWLiveIdle,     // a session finished its turn recently
    CWLiveWorking,  // a session is busy: generating or running tools
    CWLiveWaiting   // a session is waiting for you: a permission or a question
};
NSString *CWLiveStateName(CWLiveState state);

// Sessions idle longer than this put Clawd to sleep.
extern const NSTimeInterval CWLiveSleepAfter;

@interface CWClaudeMonitor : NSObject
- (instancetype)initWithClaudeDirectory:(NSString *)directory;
@property(nonatomic, copy) NSString *claudeDirectory;
@property(nonatomic, readonly) CWLiveState state;
// Remaining limits: the newest of Claude's usage endpoint (fetched on demand)
// and the optional status line bridge file.
- (CWLimits)limitsAtDate:(NSDate *)date;
// Fetches usage unless a fetch is running or the last one is under a minute
// old (five minutes after a failure). Results arrive on the main queue.
- (void)refreshUsageIfStale;
// Replaceable for tests. The default reads Claude Code's own sign-in from the
// Keychain and asks api.anthropic.com/api/oauth/usage; it never refreshes or
// stores the token. Call completion with the usage JSON, or nil on failure.
@property(nonatomic, copy) void (^usageFetcher)(void (^completion)(NSDictionary *usage));
// Re-reads the files at most once a second.
- (void)pollIfNeeded;
- (void)poll;
@end

// Turns live state changes into continuous acting: finish the current
// activity, run to where the next one happens, then start it.
typedef struct {
    BOOL started;
    CWLiveState target, pending, holding;
    double pendingSince, lastNow;
    int phase;                  // 0 hold, 1 outro, 2 run
    CWActivity outroActivity;
    double phaseStart, outroAge, outroLength;
    double anchorX; BOOL facingRight;
    double runFrom, runTo;
    double wanderBase;
} CWDirector;

void CWDirectorUpdate(CWDirector *director, CWLiveState state, double now, CGFloat width);
CWBeat CWDirectorBeat(const CWDirector *director, double now, CGFloat width);
