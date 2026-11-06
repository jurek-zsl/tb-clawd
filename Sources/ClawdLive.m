#import "ClawdLive.h"
#import <math.h>
#import <signal.h>
#import <errno.h>
#import <Security/Security.h>

const NSTimeInterval CWLiveSleepAfter = 5*60;

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
    // From the usage endpoint.
    BOOL _apiAvailable, _fetching, _lastFailed;
    double _apiTime, _lastAttempt;
    CWWindowRecord _apiFiveHour, _apiSevenDay;
}

- (instancetype)initWithClaudeDirectory:(NSString *)directory {
    self = [super init];
    if (self) {
        _claudeDirectory = [directory copy]; _lastPoll = -100; _state = CWLiveAsleep; _lastAttempt = -1e9;
        _usageFetcher = [CWClaudeMonitor defaultUsageFetcher];
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
}

// ---------------------------------------------------------- usage fetch ---

static NSString *const CWUsageURL = @"https://api.anthropic.com/api/oauth/usage";
static NSString *const CWUsageBeta = @"oauth-2025-04-20";
static NSString *const CWCredentialsService = @"Claude Code-credentials";

// Claude Code's own sign-in, read-only. macOS asks once whether Pock may read
// it. The token is used for this one request and never stored or refreshed:
// refreshing would rotate it underneath Claude Code.
static NSString *ReadAccessToken(void) {
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: CWCredentialsService,
        (__bridge id)kSecReturnData: @YES,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne,
    };
    CFTypeRef result = NULL;
    if (SecItemCopyMatching((__bridge CFDictionaryRef)query, &result) != errSecSuccess || !result) return nil;
    NSData *data = CFBridgingRelease(result);
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    NSDictionary *oauth = [json isKindOfClass:NSDictionary.class] ? json[@"claudeAiOauth"] : nil;
    if (![oauth isKindOfClass:NSDictionary.class]) return nil;
    NSString *token = oauth[@"accessToken"];
    double expires = ParseTime(oauth[@"expiresAt"]);
    if (![token isKindOfClass:NSString.class] || !token.length) return nil;
    if (!isnan(expires) && expires < NSDate.date.timeIntervalSince1970) return nil;
    return token;
}

+ (void (^)(void (^)(NSDictionary *)))defaultUsageFetcher {
    return ^(void (^completion)(NSDictionary *)) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            NSString *token = ReadAccessToken();
            if (!token) { completion(nil); return; }
            NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:CWUsageURL]];
            request.timeoutInterval = 10;
            [request setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
            [request setValue:CWUsageBeta forHTTPHeaderField:@"anthropic-beta"];
            [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
            [request setValue:@"clawd-touchbar" forHTTPHeaderField:@"User-Agent"];
            NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
            NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration];
            [[session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
                id json = (!error && status == 200 && data) ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
                completion([json isKindOfClass:NSDictionary.class] ? json : nil);
            }] resume];
            [session finishTasksAndInvalidate];
        });
    };
}

- (void)refreshUsageIfStale {
    double now = NSDate.date.timeIntervalSince1970;
    double wait = _lastFailed ? 5*60 : 60;
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
    if (_lastFailed) return;
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
    BOOL useAPI = _apiAvailable && (!_fileAvailable || _apiTime >= _fileTime);
    if (useAPI) {
        limits.available = YES;
        limits.fiveHour = WindowAt(_apiFiveHour, now); limits.sevenDay = WindowAt(_apiSevenDay, now);
    } else if (_fileAvailable) {
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
        case CWActivityCode: return 1.0;
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
            b.activity = CWActivityCode; b.anchorX = CWAnchorMax(width); b.facingRight = NO; break;
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
