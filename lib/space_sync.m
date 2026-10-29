#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Carbon/Carbon.h>
#import <dlfcn.h>
#import <spawn.h>
#import <unistd.h>
#import <fcntl.h>
#import <sys/wait.h>
#import <sys/socket.h>
#import <sys/un.h>

extern char **environ;

typedef int (*MainConnFunc)(void);
typedef uint64_t (*ActiveSpaceFunc)(int);
typedef CFArrayRef (*CopySpacesFunc)(int);

static MainConnFunc getConn = NULL;
static ActiveSpaceFunc getActiveSpace = NULL;
static CopySpacesFunc copySpaces = NULL;

#define kCGSEventGesture 29
#define kCGSEventDockControl 30
#define kIOHIDEventTypeDockSwipe 23
#define kCGGestureMotionHorizontal 1
#define NOSWOOSH_TAG 0x4E535753

static volatile int s_cachedCurrentSpace = 1;
static volatile int s_cachedTotalSpaces = 2;
static BOOL s_swipeTracking = NO;
static BOOL s_swipeFired = NO;
static CFMachPortRef s_eventTap = NULL;

static void init_skylight(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        void *sl = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY);
        if (sl) {
            getConn = (MainConnFunc)dlsym(sl, "SLSMainConnectionID");
            getActiveSpace = (ActiveSpaceFunc)dlsym(sl, "SLSGetActiveSpace");
            copySpaces = (CopySpacesFunc)dlsym(sl, "SLSCopyManagedDisplaySpaces");
            typedef int (*SetHotKeyFn)(int, bool);
            SetHotKeyFn setHotKey = (SetHotKeyFn)dlsym(sl, "SLSSetSymbolicHotKeyEnabled");
            if (setHotKey) {
                setHotKey(79, false);
                setHotKey(81, false);
            }
        }
    });
}

static const char *target_space_file_path(void) {
    static char path[128] = "";
    if (!path[0]) {
        snprintf(path, sizeof(path), "/tmp/.jkkonfig_target_space_%d", (int)getuid());
    }
    return path;
}

static void record_switch_target(int idx) {
    FILE *f = fopen(target_space_file_path(), "w");
    if (f) {
        fprintf(f, "%d\n", idx);
        fclose(f);
    }
}

static int consume_switch_target(void) {
    const char *p = target_space_file_path();
    FILE *f = fopen(p, "r");
    if (!f) return 0;
    int val = 0;
    if (fscanf(f, "%d", &val) != 1) val = 0;
    fclose(f);
    unlink(p);
    return val;
}

static int get_current_space_index(void) {
    init_skylight();
    if (!getConn || !copySpaces) return 1;
    int cid = getConn();
    uint64_t curId = getActiveSpace ? getActiveSpace(cid) : 0;
    
    CFArrayRef arr = copySpaces(cid);
    if (!arr) return 1;
    CFIndex count = CFArrayGetCount(arr);
    if (count == 0) { CFRelease(arr); return 1; }
    
    int result = 1;
    for (CFIndex d = 0; d < count; d++) {
        CFDictionaryRef displayDict = (CFDictionaryRef)CFArrayGetValueAtIndex(arr, d);
        if (curId == 0) {
            CFDictionaryRef curSpaceDict = (CFDictionaryRef)CFDictionaryGetValue(displayDict, CFSTR("Current Space"));
            if (curSpaceDict) {
                CFNumberRef curIdNum = (CFNumberRef)CFDictionaryGetValue(curSpaceDict, CFSTR("ManagedSpaceID"));
                long long cidVal = 0;
                if (curIdNum) CFNumberGetValue(curIdNum, kCFNumberLongLongType, &cidVal);
                curId = (uint64_t)cidVal;
            }
        }
        
        CFArrayRef spacesArr = (CFArrayRef)CFDictionaryGetValue(displayDict, CFSTR("Spaces"));
        if (!spacesArr) continue;
        
        CFIndex nSpaces = CFArrayGetCount(spacesArr);
        for (CFIndex i = 0; i < nSpaces; i++) {
            CFDictionaryRef sDict = (CFDictionaryRef)CFArrayGetValueAtIndex(spacesArr, i);
            CFNumberRef sIdNum = (CFNumberRef)CFDictionaryGetValue(sDict, CFSTR("ManagedSpaceID"));
            long long sId = 0;
            if (sIdNum) CFNumberGetValue(sIdNum, kCFNumberLongLongType, &sId);
            if ((uint64_t)sId == curId) {
                result = (int)(i + 1);
                CFRelease(arr);
                return result;
            }
        }
    }
    CFRelease(arr);
    return result;
}

static int get_spaces_count(void) {
    init_skylight();
    if (!getConn || !copySpaces) return 9;
    int cid = getConn();
    CFArrayRef arr = copySpaces(cid);
    if (!arr) return 9;
    CFIndex count = CFArrayGetCount(arr);
    if (count == 0) { CFRelease(arr); return 9; }
    
    int result = 1;
    for (CFIndex d = 0; d < count; d++) {
        CFDictionaryRef disp = (CFDictionaryRef)CFArrayGetValueAtIndex(arr, d);
        CFArrayRef spaces = (CFArrayRef)CFDictionaryGetValue(disp, CFSTR("Spaces"));
        if (spaces) {
            result = (int)CFArrayGetCount(spaces);
            break;
        }
    }
    CFRelease(arr);
    return result > 0 ? result : 1;
}

static void post_dock_swipe(int phase, BOOL right) {
    CGEventRef ev = CGEventCreate(NULL);
    if (!ev) return;
    double progress = 1e-4 * (right ? 1.0 : -1.0);
    double velocity = 2000.0 * (right ? 1.0 : -1.0);
    CGEventSetIntegerValueField(ev, 55, kCGSEventDockControl);
    CGEventSetIntegerValueField(ev, 110, kIOHIDEventTypeDockSwipe);
    CGEventSetIntegerValueField(ev, 132, phase);
    CGEventSetDoubleValueField(ev, 124, progress);
    CGEventSetIntegerValueField(ev, 123, kCGGestureMotionHorizontal);
    CGEventSetDoubleValueField(ev, 129, velocity);
    CGEventSetDoubleValueField(ev, 130, velocity);
    CGEventSetIntegerValueField(ev, kCGEventSourceUserData, NOSWOOSH_TAG);
    CGEventPost(kCGSessionEventTap, ev);
    CFRelease(ev);
}

static void instant_swipe(BOOL right) {
    post_dock_swipe(1, right);
    post_dock_swipe(2, right);
    post_dock_swipe(4, right);
}

static const char *get_as_path(void) {
    const char *env = getenv("JKKONFIG_AEROSPACE");
    if (env && env[0]) return env;
    if (access("/opt/homebrew/bin/aerospace", X_OK) == 0) return "/opt/homebrew/bin/aerospace";
    if (access("/usr/local/bin/aerospace", X_OK) == 0) return "/usr/local/bin/aerospace";
    return "aerospace";
}

static const char *get_jkkonfig_path(void) {
    const char *env = getenv("JKKONFIG_BIN");
    if (env && env[0]) return env;
    const char *home = getenv("HOME");
    if (home) {
        static char pfad[1024];
        snprintf(pfad, sizeof(pfad), "%s/.config/jkkonfig/bin/jkkonfig", home);
        if (access(pfad, X_OK) == 0) return pfad;
        snprintf(pfad, sizeof(pfad), "%s/bin/jkkonfig", home);
        if (access(pfad, X_OK) == 0) return pfad;
    }
    return NULL;
}

static void spawn_as_workspace(int ws) {
    const char *as = get_as_path();
    char wsStr[16];
    snprintf(wsStr, sizeof(wsStr), "%d", ws);
    char *const argv[] = {(char *)as, "workspace", wsStr, NULL};
    
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0);
    posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0);
    
    pid_t pid;
    if (posix_spawn(&pid, as, &actions, NULL, argv, environ) == 0) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
            int status;
            waitpid(pid, &status, 0);
        });
    }
    posix_spawn_file_actions_destroy(&actions);
}

static void send_as_workspace(int ws) {
    const char *user = getenv("USER");
    if (!user || !user[0]) user = "jk";
    char sock_path[128];
    snprintf(sock_path, sizeof(sock_path), "/tmp/bobko.aerospace-%s.sock", user);
    
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        spawn_as_workspace(ws);
        return;
    }
    
    struct timeval tv = { .tv_sec = 0, .tv_usec = 50000 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
    
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, sock_path, sizeof(addr.sun_path) - 1);
    
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        close(fd);
        spawn_as_workspace(ws);
        return;
    }
    
    uint32_t ver = 1;
    if (write(fd, &ver, sizeof(ver)) != sizeof(ver)) { close(fd); spawn_as_workspace(ws); return; }
    uint32_t server_ver = 0;
    if (read(fd, &server_ver, sizeof(server_ver)) != sizeof(server_ver)) { close(fd); spawn_as_workspace(ws); return; }
    
    char req[128];
    int req_len = snprintf(req, sizeof(req), "{\"args\":[\"workspace\",\"%d\"],\"stdin\":\"\",\"windowId\":null,\"workspace\":null}", ws);
    uint32_t len_prefix = (uint32_t)req_len;
    if (write(fd, &len_prefix, sizeof(len_prefix)) != sizeof(len_prefix) || write(fd, req, req_len) != req_len) {
        close(fd);
        spawn_as_workspace(ws);
        return;
    }
    
    uint32_t ans_len = 0;
    if (read(fd, &ans_len, sizeof(ans_len)) == sizeof(ans_len) && ans_len < 4096) {
        char buf[ans_len + 1];
        read(fd, buf, ans_len);
    }
    close(fd);
}

static int switch_to_space_index(int targetIdx) {
    if (targetIdx < 1) return 1;
    init_skylight();
    int cur = get_current_space_index();
    if (cur == targetIdx) return 0;
    
    int total = get_spaces_count();
    if (targetIdx > total) targetIdx = total;
    if (cur == targetIdx) return 0;
    
    s_cachedCurrentSpace = targetIdx;
    s_cachedTotalSpaces = total;
    record_switch_target(targetIdx);
    
    int diff = targetIdx - cur;
    BOOL right = (diff > 0);
    int steps = abs(diff);
    for (int i = 0; i < steps; i++) {
        instant_swipe(right);
        if (i + 1 < steps) usleep(15000);
    }
    
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.15]];
    return 0;
}

static int sync_focused_workspace(void) {
    char cmd[512];
    snprintf(cmd, sizeof(cmd), "%s list-workspaces --focused 2>/dev/null", get_as_path());
    FILE *fp = popen(cmd, "r");
    if (!fp) return 1;
    char buf[64];
    int target = 0;
    if (fgets(buf, sizeof(buf), fp)) {
        target = atoi(buf);
    }
    pclose(fp);
    if (target >= 1 && target <= 9) {
        return switch_to_space_index(target);
    }
    return 1;
}

@interface SpaceSync : NSObject
- (void)syncWorkspace;
- (void)spaceChanged:(NSNotification *)note;
- (void)watchTimer:(NSTimer *)timer;
@end

static CGEventRef tap_callback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *refcon) {
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        s_swipeTracking = NO;
        s_swipeFired = NO;
        if (s_eventTap) {
            CGEventTapEnable(s_eventTap, true);
        }
        return event;
    }
    
    int64_t et = CGEventGetIntegerValueField(event, 55);
    int64_t tag = CGEventGetIntegerValueField(event, kCGEventSourceUserData);
    if ((et == kCGSEventDockControl || et == kCGSEventGesture) && tag == NOSWOOSH_TAG) {
        return event;
    }
    
    if (et == kCGSEventDockControl &&
        CGEventGetIntegerValueField(event, 110) == kIOHIDEventTypeDockSwipe &&
        CGEventGetIntegerValueField(event, 123) == kCGGestureMotionHorizontal) {
        int64_t phase = CGEventGetIntegerValueField(event, 132);
        if (phase == 1) { // began
            s_swipeTracking = YES;
            s_swipeFired = NO;
            return NULL;
        } else if (phase == 2) { // changed
            if (s_swipeTracking && !s_swipeFired) {
                double progress = CGEventGetDoubleValueField(event, 124);
                if (progress != 0.0) {
                    s_swipeFired = YES;
                    BOOL right = (progress > 0.0);
                    int cur = s_cachedCurrentSpace;
                    int total = s_cachedTotalSpaces;
                    int target = cur + (right ? 1 : -1);
                    if (target >= 1 && target <= total) {
                        s_cachedCurrentSpace = target;
                        record_switch_target(target);
                        instant_swipe(right);
                        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
                            send_as_workspace(target);
                        });
                    }
                }
            }
            return s_swipeTracking ? NULL : event;
        } else if (phase == 4) { // ended
            if (s_swipeTracking && !s_swipeFired) {
                double vel = CGEventGetDoubleValueField(event, 129);
                if (vel != 0.0) {
                    BOOL right = (vel > 0.0);
                    int cur = s_cachedCurrentSpace;
                    int total = s_cachedTotalSpaces;
                    int target = cur + (right ? 1 : -1);
                    if (target >= 1 && target <= total) {
                        s_cachedCurrentSpace = target;
                        record_switch_target(target);
                        instant_swipe(right);
                        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
                            send_as_workspace(target);
                        });
                    }
                }
            }
            s_swipeTracking = NO;
            s_swipeFired = NO;
            return NULL;
        } else if (phase == 8) { // cancelled
            s_swipeTracking = NO;
            s_swipeFired = NO;
            return NULL;
        }
    }
    
    if (et == kCGSEventGesture && s_swipeTracking) {
        return NULL;
    }
    
    return event;
}

static OSStatus hotkey_handler(EventHandlerCallRef nextHandler, EventRef theEvent, void *userData) {
    EventHotKeyID hotKeyID;
    GetEventParameter(theEvent, kEventParamDirectObject, typeEventHotKeyID, NULL, sizeof(hotKeyID), NULL, &hotKeyID);
    BOOL right = (hotKeyID.id == 2);
    int cur = s_cachedCurrentSpace;
    int total = s_cachedTotalSpaces;
    int target = cur + (right ? 1 : -1);
    if (target >= 1 && target <= total) {
        s_cachedCurrentSpace = target;
        record_switch_target(target);
        instant_swipe(right);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
            send_as_workspace(target);
        });
    }
    return noErr;
}

@implementation SpaceSync {
    int _lastSpace;
    char _jkkonfigBin[1024];
    dispatch_source_t _timerSource;
    dispatch_queue_t _timerQueue;
    NSTimer *_watchTimer;
}

- (instancetype)initWithJkkonfig:(const char *)jkkonfig {
    if (self = [super init]) {
        _lastSpace = -1;
        if (jkkonfig) {
            strncpy(_jkkonfigBin, jkkonfig, sizeof(_jkkonfigBin) - 1);
        } else {
            const char *env = get_jkkonfig_path();
            if (env) {
                strncpy(_jkkonfigBin, env, sizeof(_jkkonfigBin) - 1);
            } else {
                _jkkonfigBin[0] = '\0';
            }
        }
        
        [self syncWorkspace];
        
        [[[NSWorkspace sharedWorkspace] notificationCenter] addObserver:self
                                                               selector:@selector(spaceChanged:)
                                                                   name:NSWorkspaceActiveSpaceDidChangeNotification
                                                                 object:nil];
        
        EventTypeSpec eventType = { .eventClass = kEventClassKeyboard, .eventKind = kEventHotKeyPressed };
        InstallEventHandler(GetApplicationEventTarget(), hotkey_handler, 1, &eventType, NULL, NULL);
        EventHotKeyRef ref1, ref2;
        EventHotKeyID id1 = { .signature = 'SPSW', .id = 1 };
        EventHotKeyID id2 = { .signature = 'SPSW', .id = 2 };
        RegisterEventHotKey(123, controlKey, id1, GetApplicationEventTarget(), 0, &ref1);
        RegisterEventHotKey(124, controlKey, id2, GetApplicationEventTarget(), 0, &ref2);
        
        CGEventMask mask = (1ULL << kCGSEventGesture) | (1ULL << kCGSEventDockControl);
        s_eventTap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap, kCGEventTapOptionDefault, mask, tap_callback, (__bridge void *)self);
        if (s_eventTap) {
            CFRunLoopSourceRef src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, s_eventTap, 0);
            CFRunLoopAddSource(CFRunLoopGetCurrent(), src, kCFRunLoopCommonModes);
            CGEventTapEnable(s_eventTap, true);
        }
        
        _timerQueue = dispatch_queue_create("com.jkkonfig.spacesync.timer", DISPATCH_QUEUE_SERIAL);
        dispatch_set_target_queue(_timerQueue, dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0));
        _timerSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _timerQueue);
        dispatch_source_set_timer(_timerSource, dispatch_time(DISPATCH_TIME_NOW, 0), 25 * NSEC_PER_MSEC, 0);
        __unsafe_unretained SpaceSync *weakSelf = self;
        dispatch_source_set_event_handler(_timerSource, ^{
            [weakSelf syncWorkspace];
        });
        dispatch_resume(_timerSource);
        
        _watchTimer = [NSTimer scheduledTimerWithTimeInterval:60.0
                                                       target:self
                                                     selector:@selector(watchTimer:)
                                                     userInfo:nil
                                                      repeats:YES];
        [[NSRunLoop currentRunLoop] addTimer:_watchTimer forMode:NSRunLoopCommonModes];
    }
    return self;
}

- (void)syncWorkspace {
    int cur = get_current_space_index();
    s_cachedCurrentSpace = cur;
    s_cachedTotalSpaces = get_spaces_count();
    if (cur >= 1 && cur <= 9 && cur != _lastSpace) {
        _lastSpace = cur;
        int target = consume_switch_target();
        if (target == cur) {
            return;
        }
        send_as_workspace(cur);
    }
}

- (void)spaceChanged:(NSNotification *)note {
    [self syncWorkspace];
}

- (void)watchTimer:(NSTimer *)timer {
    if (s_eventTap && !CGEventTapIsEnabled(s_eventTap)) {
        CGEventTapEnable(s_eventTap, true);
    }
    if (_jkkonfigBin[0]) {
        char cmd[1200];
        snprintf(cmd, sizeof(cmd), "%s wachen >/dev/null 2>&1", _jkkonfigBin);
        system(cmd);
    }
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        init_skylight();
        
        if (argc > 1 && strcmp(argv[1], "--current") == 0) {
            printf("%d\n", get_current_space_index());
            return 0;
        }
        
        if (argc > 2 && strcmp(argv[1], "--switch") == 0) {
            int target = atoi(argv[2]);
            return switch_to_space_index(target);
        }
        
        if (argc > 1 && strcmp(argv[1], "--sync-focused") == 0) {
            return sync_focused_workspace();
        }
        
        const char *env_ws = getenv("AEROSPACE_FOCUSED_WORKSPACE");
        if (argc == 1 && env_ws && env_ws[0] >= '1' && env_ws[0] <= '9' && env_ws[1] == '\0') {
            return switch_to_space_index(atoi(env_ws));
        }
        
        const char *jk = get_jkkonfig_path();
        if (!jk && argc > 1 && argv[1][0] != '-') jk = argv[1];
        
        SpaceSync *sync = [[SpaceSync alloc] initWithJkkonfig:jk];
        (void)sync;
        [[NSRunLoop currentRunLoop] run];
    }
    return 0;
}
