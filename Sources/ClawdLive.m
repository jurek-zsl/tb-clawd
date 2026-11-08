#import "ClawdLive.h"
#import <math.h>
#import <signal.h>
#import <errno.h>
#import <unistd.h>

const NSTimeInterval CWLiveSleepAfter = 5*60;
// Numbers older than this are not shown; a check replaces them.
static const double kLimitsFresh = 5*60;
// While Claude Code is active the readout is kept warm so a tap never waits:
// a check every four minutes, and one shortly after each finished turn, which
// is when the numbers actually move.
static const double kWarmEvery = 4*60, kAfterTurn = 45, kRetryAfterFailure = 2*60;

NSString *CWLiveStateName(CWLiveState state) {
    switch (state) {
        case CWLiveIdle: return @"idle";
        case CWLiveWorking: return @"working";
        case CWLiveWaiting: return @"waiting";
        default: return @"asleep";
    }
}

// ------------------------------------------------------------- monitor ---

typedef struct { BOOL known; double used; double resetsAt; } CWWindowRecord;

@implementation CWClaudeMonitor {
    CFTimeInterval _lastPoll;
    // From the optional status line bridge file.
    BOOL _fileAvailable;
    double _fileTime;
    CWWindowRecord _fileFiveHour, _fileSevenDay;
    // From asking the Claude Code binary (see runClaudeUsage:).
    BOOL _apiAvailable, _fetching, _lastFailed;
    CWLiveState _previousState;
    double _apiTime, _lastAttempt;
    CWWindowRecord _apiFiveHour, _apiSevenDay;
    char _note[12];
    pid_t _probePID;    // the claude process this monitor started, if any
}

- (instancetype)initWithClaudeDirectory:(NSString *)directory {
    self = [super init];
    if (self) {
        _claudeDirectory = [directory copy]; _lastPoll = -100; _state = CWLiveAsleep; _lastAttempt = -1e9;
        _usageTimeout = 25;
        __weak CWClaudeMonitor *weakSelf = self;
        _usageFetcher = ^(void (^completion)(NSDictionary *)) { [weakSelf runClaudeUsage:completion]; };
    }
    return self;
}

- (void)setClaudeDirectory:(NSString *)claudeDirectory {
    _claudeDirectory = [claudeDirectory copy];
    _lastPoll = -100;
}

static BOOL ProcessAlive(pid_t pid) {
    if (pid <= 0) return NO;
    return kill(pid, 0) == 0 || errno == EPERM;
}
static double Number(id value) { return [value isKindOfClass:NSNumber.class] ? [value doubleValue] : NAN; }

static double ParseTime(id value) {
    if ([value isKindOfClass:NSNumber.class]) {
        double t = [value doubleValue];
        return t > 1e12 ? t/1000 : t;     // milliseconds or seconds since 1970
    }
    if ([value isKindOfClass:NSString.class]) {
        NSString *text = value;
        if (text.doubleValue > 1e9) return ParseTime(@(text.doubleValue));
        NSISO8601DateFormatter *formatter = [NSISO8601DateFormatter new];
        formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
        NSDate *date = [formatter dateFromString:text];
        if (!date) { formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime; date = [formatter dateFromString:text]; }
        return date ? date.timeIntervalSince1970 : NAN;
    }
    return NAN;
}

static CWWindowRecord ParseWindow(id value) {
    CWWindowRecord record = {0};
    if (![value isKindOfClass:NSDictionary.class]) return record;
    NSDictionary *window = value;
    double used = Number(window[@"used_percentage"]);
    if (isnan(used)) used = Number(window[@"utilization"]);
    if (isnan(used)) return record;
    record.known = YES;
    record.used = used;
    record.resetsAt = ParseTime(window[@"resets_at"]);
    return record;
}

- (void)pollIfNeeded {
    CFTimeInterval now = CFAbsoluteTimeGetCurrent();
    if (now - _lastPoll < 1) return;
    [self poll];
}

- (void)poll {
    _lastPoll = CFAbsoluteTimeGetCurrent();
    NSFileManager *files = NSFileManager.defaultManager;
    NSString *sessions = [_claudeDirectory stringByAppendingPathComponent:@"sessions"];
    double nowMs = NSDate.date.timeIntervalSince1970 * 1000;
    BOOL busy = NO, waiting = NO, recent = NO;
    for (NSString *name in [files contentsOfDirectoryAtPath:sessions error:NULL]) {
        if (![name.pathExtension isEqualToString:@"json"]) continue;
        NSData *data = [NSData dataWithContentsOfFile:[sessions stringByAppendingPathComponent:name]];
        id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
        if (![json isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *session = json;
        // Stale files from exited sessions and pre-warmed spares do not count.
        if (!ProcessAlive((pid_t)Number(session[@"pid"]))) continue;
        // The widget's own limits check is a short-lived Claude session: it must
        // not make Clawd run to the laptop.
        if ((pid_t)Number(session[@"pid"]) == [self probePID]) continue;
        if ([session[@"spare"] respondsToSelector:@selector(boolValue)] && [session[@"spare"] boolValue]) continue;
        NSString *status = [session[@"status"] isKindOfClass:NSString.class] ? [session[@"status"] lowercaseString] : @"";
        if ([status isEqualToString:@"busy"]) busy = YES;
        else if ([status containsString:@"wait"] || [status isEqualToString:@"requires_action"]) waiting = YES;
        else {
            double updated = Number(session[@"statusUpdatedAt"]);
            if (isnan(updated)) updated = Number(session[@"updatedAt"]);
            if (!isnan(updated) && nowMs - updated < CWLiveSleepAfter * 1000) recent = YES;
        }
    }
    _previousState = _state;
    _state = waiting ? CWLiveWaiting : busy ? CWLiveWorking : recent ? CWLiveIdle : CWLiveAsleep;

    NSString *limitsPath = [[_claudeDirectory stringByAppendingPathComponent:@"clawd"] stringByAppendingPathComponent:@"limits.json"];
    NSData *limitsData = [NSData dataWithContentsOfFile:limitsPath];
    id limitsJSON = limitsData ? [NSJSONSerialization JSONObjectWithData:limitsData options:0 error:NULL] : nil;
    _fileAvailable = NO;
    if ([limitsJSON isKindOfClass:NSDictionary.class]) {
        id rateLimits = limitsJSON[@"rate_limits"] ?: limitsJSON;
        if ([rateLimits isKindOfClass:NSDictionary.class]) {
            _fileFiveHour = ParseWindow(rateLimits[@"five_hour"]);
            _fileSevenDay = ParseWindow(rateLimits[@"seven_day"]);
            _fileAvailable = _fileFiveHour.known || _fileSevenDay.known;
            NSDate *modified = [files attributesOfItemAtPath:limitsPath error:NULL].fileModificationDate;
            _fileTime = modified ? modified.timeIntervalSince1970 : 0;
        }
    }
    // Keep the readout ready while Claude Code is in use.
    BOOL finishedTurn = (_previousState == CWLiveWorking || _previousState == CWLiveWaiting) && _state == CWLiveIdle;
    if (finishedTurn) [self fetchUsageIfQuietFor:kAfterTurn];
    else if (_state != CWLiveAsleep) [self fetchUsageIfQuietFor:kWarmEvery];
}

- (NSString *)limitsNote { return [NSString stringWithUTF8String:_note]; }
- (pid_t)probePID { @synchronized (self) { return _probePID; } }
- (void)setProbePID:(pid_t)pid { @synchronized (self) { _probePID = pid; } }

// ---------------------------------------------------------- usage fetch ---

// Remaining limits come from Claude Code itself: a one-line, tool-less prompt
// to the cheapest model through `claude -p --output-format stream-json`, which
// emits a `rate_limit_event` with each window's utilization (0...1) and reset
// time. Claude Code does its own sign-in, renewal and Keychain access, so the
// widget never sees a credential or a token. The check shows up as a short
// Claude session; the monitor ignores it by process id.
- (NSString *)resolveClaudeExecutable {
    NSFileManager *files = NSFileManager.defaultManager;
    if (_claudeExecutable.length) return [files isExecutableFileAtPath:_claudeExecutable] ? _claudeExecutable : nil;
    NSString *home = NSHomeDirectory();
    NSMutableArray<NSString *> *candidates = [NSMutableArray arrayWithObjects:
        [home stringByAppendingPathComponent:@".local/bin/claude"],
        [home stringByAppendingPathComponent:@".claude/local/claude"],
        @"/opt/homebrew/bin/claude", @"/usr/local/bin/claude", nil];
    for (NSString *dir in [NSProcessInfo.processInfo.environment[@"PATH"] componentsSeparatedByString:@":"])
        if (dir.length) [candidates addObject:[dir stringByAppendingPathComponent:@"claude"]];
    // The binary bundled in the Claude desktop app, newest version first.
    NSString *bundled = [home stringByAppendingPathComponent:@"Library/Application Support/Claude/claude-code"];
    NSArray<NSString *> *versions = [[files contentsOfDirectoryAtPath:bundled error:NULL] sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        return [b compare:a options:NSNumericSearch];
    }];
    for (NSString *version in versions) {
        NSString *versionDir = [bundled stringByAppendingPathComponent:version];
        for (NSString *build in [files contentsOfDirectoryAtPath:versionDir error:NULL])
            [candidates addObject:[versionDir stringByAppendingPathComponent:[build stringByAppendingPathComponent:@"claude.app/Contents/MacOS/claude"]]];
    }
    for (NSString *path in candidates) if ([files isExecutableFileAtPath:path]) return path;
    return nil;
}

// Converts the event stream to the shape finishUsage: reads: windows as
// {utilization: percent, resets_at: epoch seconds}, or {error: "WORD"}.
static NSDictionary *UsageFromStream(NSData *output, BOOL timedOut) {
    NSDictionary *limitEvent = nil, *result = nil;
    NSString *text = [[NSString alloc] initWithData:output encoding:NSUTF8StringEncoding] ?: @"";
    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        if (![line hasPrefix:@"{"]) continue;
        id json = [NSJSONSerialization JSONObjectWithData:[line dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];
        if (![json isKindOfClass:NSDictionary.class]) continue;
        NSString *type = json[@"type"];
        if ([type isEqualToString:@"rate_limit_event"]) limitEvent = json;
        else if ([type isEqualToString:@"result"]) result = json;
    }
    NSDictionary *info = [limitEvent[@"rate_limit_info"] isKindOfClass:NSDictionary.class] ? limitEvent[@"rate_limit_info"] : nil;
    NSMutableDictionary *usage = [NSMutableDictionary dictionary];
    NSDictionary *windows = [info[@"unifiedWindows"] isKindOfClass:NSDictionary.class] ? info[@"unifiedWindows"] : nil;
    for (NSString *key in @[@"five_hour", @"seven_day"]) {
        NSDictionary *window = [windows[key] isKindOfClass:NSDictionary.class] ? windows[key] : nil;
        double utilization = Number(window[@"utilization"]);
        if (isnan(utilization)) continue;
        usage[key] = @{@"utilization": @(utilization*100), @"resets_at": window[@"resetsAt"] ?: [NSNull null]};
    }
    // Older builds report only the binding window at the top level.
    NSString *binding = [info[@"rateLimitType"] isKindOfClass:NSString.class] ? info[@"rateLimitType"] : nil;
    if (!usage.count && binding && !isnan(Number(info[@"utilization"])))
        usage[binding] = @{@"utilization": @(Number(info[@"utilization"])*100), @"resets_at": info[@"resetsAt"] ?: [NSNull null]};
    if (usage.count) return usage;
    NSString *message = [[result[@"result"] isKindOfClass:NSString.class] ? result[@"result"] : @"" lowercaseString];
    if ([message containsString:@"login"] || [message containsString:@"log in"] || [message containsString:@"authenticat"] || [message containsString:@"api key"])
        return @{@"error": @"NO LOGIN"};
    if (!timedOut && [result[@"is_error"] isEqual:@NO] && result[@"subtype"] && [result[@"subtype"] isEqual:@"success"]) return @{@"error": @"NO LIMITS"};
    return @{@"error": @"FAILED"};
}

- (void)runClaudeUsage:(void (^)(NSDictionary *))completion {
    NSString *executable = [self resolveClaudeExecutable];
    if (!executable) { completion(@{@"error": @"NO CLAUDE"}); return; }
    NSTimeInterval timeout = _usageTimeout;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSTask *task = [NSTask new];
        task.executableURL = [NSURL fileURLWithPath:executable];
        task.arguments = @[@"-p", @"ok", @"--output-format", @"stream-json", @"--verbose",
                           @"--max-turns", @"1", @"--tools", @"", @"--no-session-persistence",
                           @"--model", @"haiku", @"--setting-sources", @"",
                           @"--strict-mcp-config", @"--disable-slash-commands"];
        task.currentDirectoryURL = [NSURL fileURLWithPath:NSTemporaryDirectory()];
        NSPipe *pipe = [NSPipe pipe];
        task.standardOutput = pipe;
        task.standardInput = NSFileHandle.fileHandleWithNullDevice;
        task.standardError = NSFileHandle.fileHandleWithNullDevice;
        NSError *error = nil;
        if (![task launchAndReturnError:&error]) { completion(@{@"error": @"FAILED"}); return; }
        [self setProbePID:task.processIdentifier];
        __block BOOL timedOut = NO;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            if (task.isRunning) { timedOut = YES; [task terminate]; }
        });
        // Collect output as it arrives instead of reading to end-of-file: a
        // stray grandchild holding the pipe open must not outlive the timeout.
        NSMutableData *collected = [NSMutableData data];
        NSData *marker = [@"\"rate_limit_event\"" dataUsingEncoding:NSUTF8StringEncoding], *newline = [@"\n" dataUsingEncoding:NSUTF8StringEncoding];
        pipe.fileHandleForReading.readabilityHandler = ^(NSFileHandle *handle) {
            NSData *chunk = handle.availableData;
            @synchronized (collected) {
                [collected appendData:chunk];
                // The limits are all we want: once their line is complete, stop.
                NSRange found = [collected rangeOfData:marker options:0 range:NSMakeRange(0, collected.length)];
                if (found.location != NSNotFound && task.isRunning &&
                    [collected rangeOfData:newline options:0 range:NSMakeRange(NSMaxRange(found), collected.length - NSMaxRange(found))].location != NSNotFound)
                    [task terminate];
            }
        };
        [task waitUntilExit];
        usleep(100*1000);   // let the last chunk through
        pipe.fileHandleForReading.readabilityHandler = nil;
        [self setProbePID:0];
        NSData *output;
        @synchronized (collected) { output = [collected copy]; }
        completion(UsageFromStream(output, timedOut));
    });
}

- (void)refreshUsageIfStale { [self fetchUsageIfQuietFor:5*60]; }

- (BOOL)isFetching { return _fetching; }

// Starts a check unless one is running or the last one began less than `gap`
// seconds ago (never sooner than two minutes after a failure).
- (void)fetchUsageIfQuietFor:(double)gap {
    double now = NSDate.date.timeIntervalSince1970;
    double wait = _lastFailed ? fmax(gap, kRetryAfterFailure) : gap;
    if (_fetching || !_usageFetcher || now - _lastAttempt < wait) return;
    _fetching = YES;
    _lastAttempt = now;
    __weak CWClaudeMonitor *weakSelf = self;
    _usageFetcher(^(NSDictionary *usage) {
        dispatch_async(dispatch_get_main_queue(), ^{
            CWClaudeMonitor *monitor = weakSelf;
            if (monitor) [monitor finishUsage:usage];
        });
    });
}

- (void)finishUsage:(NSDictionary *)usage {
    _fetching = NO;
    CWWindowRecord five = ParseWindow(usage[@"five_hour"]), seven = ParseWindow(usage[@"seven_day"]);
    _lastFailed = !(five.known || seven.known);
    if (_lastFailed) {
        NSString *why = [usage[@"error"] isKindOfClass:NSString.class] ? usage[@"error"] : @"";
        snprintf(_note, sizeof _note, "%s", why.UTF8String);
        return;
    }
    _note[0] = 0;
    _apiFiveHour = five; _apiSevenDay = seven;
    _apiAvailable = YES;
    _apiTime = NSDate.date.timeIntervalSince1970;
}

static CWLimitWindow WindowAt(CWWindowRecord record, double now) {
    CWLimitWindow window = {record.known, record.used, isnan(record.resetsAt) ? 0 : record.resetsAt - now};
    // A window whose reset time has passed starts over at zero.
    if (record.known && !isnan(record.resetsAt) && window.resetsIn <= 0) { window.usedPercent = 0; window.resetsIn = 0; }
    return window;
}

- (CWLimits)limitsAtDate:(NSDate *)date {
    double now = date.timeIntervalSince1970;
    CWLimits limits = {0};
    limits.loading = _fetching;
    memcpy(limits.note, _note, sizeof limits.note);
    // Only numbers that were true a moment ago: the newest source, if fresh.
    BOOL apiFresh = _apiAvailable && now - _apiTime < kLimitsFresh;
    BOOL fileFresh = _fileAvailable && now - _fileTime < kLimitsFresh;
    if (apiFresh && (!fileFresh || _apiTime >= _fileTime)) {
        limits.available = YES;
        limits.fiveHour = WindowAt(_apiFiveHour, now); limits.sevenDay = WindowAt(_apiSevenDay, now);
    } else if (fileFresh) {
        limits.available = YES;
        limits.fiveHour = WindowAt(_fileFiveHour, now); limits.sevenDay = WindowAt(_fileSevenDay, now);
    }
    return limits;
}
@end

// ------------------------------------------------------------ director ---

static const double kDebounce = .8;

static double OutroLength(CWActivity activity) {
    switch (activity) {
        case CWActivityCode: case CWActivityServer: case CWActivityBug: case CWActivityDuck: return 1.0;
        case CWActivityCoffee: return 1.3;
        case CWActivityStretch: return 1.2;
        case CWActivityNap: case CWActivityWave: return .9;
        default: return 0;
    }
}

// Where each state is acted out. Waiting happens wherever Clawd stands.
static double HomeAnchor(const CWDirector *d, CWLiveState state, CGFloat width) {
    switch (state) {
        case CWLiveWorking: return CWAnchorMax(width);
        case CWLiveWaiting: return d->anchorX;
        default: return CWAnchorMin(width);
    }
}

static CWBeat HoldBeat(const CWDirector *d, double now, CGFloat width) {
    double age = fmax(0, now - d->phaseStart);
    CWBeat b = {CWActivityNap, age, INFINITY, CWAnchorMin(width), 0, now, YES};
    switch (d->holding) {
        case CWLiveWorking:
            // Laptop, server rack, bug and rubber duck in turn, starting at the laptop.
            b = CWWorkBeat(fmax(0, now - d->wanderBase), width);
            b.clock = now;
            break;
        case CWLiveWaiting: {
            double anchor = fmax(CWAnchorMin(width), fmin(CWAnchorMax(width), d->anchorX));
            b.activity = CWActivityWave; b.anchorX = anchor;
            b.facingRight = anchor <= (CWAnchorMin(width)+CWAnchorMax(width))/2;
            break;
        }
        case CWLiveIdle: {
            // The autonomous loop, which starts by running right from home.
            b = CWTimelineBeat(fmax(0, now - d->wanderBase), width);
            b.clock = now;
            break;
        }
        default: break;
    }
    return b;
}

CWBeat CWDirectorBeat(const CWDirector *d, double now, CGFloat width) {
    if (d->phase == 1) {
        double age = d->outroAge + fmax(0, now - d->phaseStart);
        CWBeat b = {d->outroActivity, age, d->outroAge + d->outroLength, d->anchorX, 0, now, d->facingRight};
        return b;
    }
    if (d->phase == 2) {
        double travel = fabs(d->runTo - d->runFrom);
        double distance = CWRunDistance(now - d->phaseStart, travel);
        BOOL right = d->runTo > d->runFrom;
        CWBeat b = {CWActivityRun, now - d->phaseStart, CWRunTime(travel), d->runFrom + (right ? distance : -distance), distance, now, right};
        return b;
    }
    return HoldBeat(d, now, width);
}

static void BeginHold(CWDirector *d, double t, CGFloat width) {
    d->phase = 0;
    d->holding = d->target;
    d->phaseStart = t;
    d->wanderBase = t;
    if (d->target != CWLiveWaiting) d->anchorX = HomeAnchor(d, d->target, width);
}

static void BeginRun(CWDirector *d, double from, double t, CGFloat width) {
    double to = HomeAnchor(d, d->target, width);
    d->anchorX = from;
    if (fabs(to - from) < .5) { BeginHold(d, t, width); return; }
    d->phase = 2; d->phaseStart = t; d->runFrom = from; d->runTo = to;
}

void CWDirectorUpdate(CWDirector *d, CWLiveState state, double now, CGFloat width) {
    if (!d->started) {
        // First sight: already in place, already settled into the pose.
        *d = (CWDirector){0};
        d->started = YES;
        d->target = d->pending = d->holding = state;
        d->pendingSince = now; d->lastNow = now;
        d->anchorX = state == CWLiveWaiting ? CWAnchorMax(width) : HomeAnchor(d, state, width);
        BeginHold(d, now - 3, width);
        return;
    }
    if (now < d->lastNow) return;
    d->lastNow = now;
    if (state != d->pending) { d->pending = state; d->pendingSince = now; }
    if (d->pending != d->target && now - d->pendingSince >= kDebounce) d->target = d->pending;

    for (int guard = 0; guard < 8; guard++) {
        if (d->phase == 0) {
            if (d->holding == d->target) return;
            CWBeat b = HoldBeat(d, now, width);
            d->anchorX = b.anchorX; d->facingRight = b.facingRight;
            if (b.activity == CWActivityRun) { BeginRun(d, b.anchorX, now, width); continue; }
            double length = OutroLength(b.activity);
            if (isfinite(b.duration)) length = fmin(length, fmax(0, b.duration - b.age));
            d->phase = 1; d->outroActivity = b.activity; d->outroAge = b.age;
            d->outroLength = length; d->phaseStart = now;
            continue;
        }
        if (d->phase == 1) {
            double end = d->phaseStart + d->outroLength;
            if (now < end) return;
            if (d->target == CWLiveWaiting) BeginHold(d, end, width);
            else BeginRun(d, d->anchorX, end, width);
            continue;
        }
        // Running: a new destination turns him around from where he is.
        double travel = fabs(d->runTo - d->runFrom);
        double to = HomeAnchor(d, d->target, width);
        CWBeat b = CWDirectorBeat(d, now, width);
        if (d->target == CWLiveWaiting) { d->anchorX = b.anchorX; BeginHold(d, now, width); return; }
        if (fabs(to - d->runTo) > .5) { BeginRun(d, b.anchorX, now, width); return; }
        double end = d->phaseStart + CWRunTime(travel);
        if (now < end) return;
        d->anchorX = d->runTo;
        BeginHold(d, end, width);
    }
}
