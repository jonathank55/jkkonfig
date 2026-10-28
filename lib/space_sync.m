#import <Cocoa/Cocoa.h>
#import <dlfcn.h>
#import <unistd.h>

typedef int (*MainConnFunc)(void);
typedef uint64_t (*ActiveSpaceFunc)(int);
typedef CFArrayRef (*CopySpacesFunc)(int);
typedef void (*SetSpaceFunc)(int, CFStringRef, uint64_t);

static MainConnFunc getConn = NULL;
static ActiveSpaceFunc getActiveSpace = NULL;
static CopySpacesFunc copySpaces = NULL;
static SetSpaceFunc setSpace = NULL;

static void init_skylight(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        void *sl = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY);
        if (sl) {
            getConn = (MainConnFunc)dlsym(sl, "SLSMainConnectionID");
            getActiveSpace = (ActiveSpaceFunc)dlsym(sl, "SLSGetActiveSpace");
            copySpaces = (CopySpacesFunc)dlsym(sl, "SLSCopyManagedDisplaySpaces");
            setSpace = (SetSpaceFunc)dlsym(sl, "SLSManagedDisplaySetCurrentSpace");
        }
    });
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

static int switch_to_space_index(int targetIdx) {
    init_skylight();
    if (!getConn || !copySpaces || !setSpace || targetIdx < 1) return 1;
    int cid = getConn();
    CFArrayRef arr = copySpaces(cid);
    if (!arr || CFArrayGetCount(arr) == 0) return 1;
    
    CFDictionaryRef disp = (CFDictionaryRef)CFArrayGetValueAtIndex(arr, 0);
    CFStringRef dispUUID = (CFStringRef)CFDictionaryGetValue(disp, CFSTR("Display Identifier"));
    CFArrayRef spaces = (CFArrayRef)CFDictionaryGetValue(disp, CFSTR("Spaces"));
    if (!spaces || CFArrayGetCount(spaces) < targetIdx) {
        CFRelease(arr);
        return 1;
    }
    
    CFDictionaryRef targetDict = (CFDictionaryRef)CFArrayGetValueAtIndex(spaces, targetIdx - 1);
    CFNumberRef idNum = (CFNumberRef)CFDictionaryGetValue(targetDict, CFSTR("ManagedSpaceID"));
    long long sId = 0;
    if (idNum) CFNumberGetValue(idNum, kCFNumberLongLongType, &sId);
    
    if (sId > 0 && dispUUID) {
        setSpace(cid, dispUUID, (uint64_t)sId);
    }
    CFRelease(arr);
    return 0;
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
- (void)pollTimer:(NSTimer *)timer;
- (void)watchTimer:(NSTimer *)timer;
@end

@implementation SpaceSync {
    int _lastSpace;
    char _jkkonfigBin[1024];
    NSTimer *_pollTimer;
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
        
        _pollTimer = [NSTimer scheduledTimerWithTimeInterval:0.10
                                                      target:self
                                                    selector:@selector(pollTimer:)
                                                    userInfo:nil
                                                     repeats:YES];
        
        _watchTimer = [NSTimer scheduledTimerWithTimeInterval:60.0
                                                       target:self
                                                     selector:@selector(watchTimer:)
                                                     userInfo:nil
                                                      repeats:YES];
    }
    return self;
}

- (void)syncWorkspace {
    int cur = get_current_space_index();
    if (cur >= 1 && cur <= 9 && cur != _lastSpace) {
        _lastSpace = cur;
        char cmd[512];
        snprintf(cmd, sizeof(cmd), "%s workspace %d >/dev/null 2>&1", get_as_path(), cur);
        system(cmd);
    }
}

- (void)pollTimer:(NSTimer *)timer {
    [self syncWorkspace];
}

- (void)spaceChanged:(NSNotification *)note {
    [self syncWorkspace];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(50 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        [self syncWorkspace];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(120 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        [self syncWorkspace];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(250 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        [self syncWorkspace];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(400 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        [self syncWorkspace];
    });
}

- (void)watchTimer:(NSTimer *)timer {
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
        
        const char *jk = get_jkkonfig_path();
        if (!jk && argc > 1 && argv[1][0] != '-') jk = argv[1];
        
        SpaceSync *sync = [[SpaceSync alloc] initWithJkkonfig:jk];
        (void)sync;
        [[NSRunLoop currentRunLoop] run];
    }
    return 0;
}
