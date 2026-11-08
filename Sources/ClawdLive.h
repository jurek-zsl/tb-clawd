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
// Remaining limits: the newest of a check through the Claude binary and the
// optional status line bridge file, and only while it is under five minutes
// old. Older numbers are never shown (`available` is NO); `loading` says a
// check is on its way.
- (CWLimits)limitsAtDate:(NSDate *)date;
// Fetches usage unless a fetch is running or the last one is under five
// minutes old (two minutes after a failure). Results arrive on the main queue.
- (void)refreshUsageIfStale;
// A check is running.
@property(nonatomic, readonly, getter=isFetching) BOOL fetching;
// How limits are fetched. The default asks the Claude Code binary (see
// ClawdLive.m); tests replace it. Call completion with usage windows
// ({five_hour: {utilization: percent, resets_at: ...}, seven_day: ...}), or
// {error: "NO CLAUDE" | "NO LOGIN" | "FAILED" | "NO LIMITS"}.
@property(nonatomic, copy) void (^usageFetcher)(void (^completion)(NSDictionary *usage));
// The claude binary to run; nil searches the usual places and the Claude
// desktop app's bundled copy.
@property(nonatomic, copy) NSString *claudeExecutable;
// Seconds before a slow check is stopped (default 25).
@property(nonatomic) NSTimeInterval usageTimeout;
// Why there are no numbers: "NO CLAUDE", "NO LOGIN", "FAILED", "NO LIMITS", or
// empty. Cleared by the next successful check.
@property(nonatomic, readonly) NSString *limitsNote;
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
