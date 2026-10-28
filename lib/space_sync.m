#import <Cocoa/Cocoa.h>
#import <dlfcn.h>
#import <unistd.h>

typedef int (*MainConnFunc)(void);
typedef uint64_t (*ActiveSpaceFunc)(int);
typedef CFArrayRef (*CopySpacesFunc)(int);

static MainConnFunc getConn = NULL;
static ActiveSpaceFunc getActiveSpace = NULL;
static CopySpacesFunc copySpaces = NULL;

static int get_current_space_index(void) {
    if (!getConn || !copySpaces) return 1;
    int cid = getConn();
    uint64_t curId = getActiveSpace ? getActiveSpace(cid) : 0;
    
    CFArrayRef arr = copySpaces(cid);
    if (!arr) return 1;
    CFIndex count = CFArrayGetCount(arr);
    if (count == 0) { CFRelease(arr); return 1; }
    
    CFDictionaryRef displayDict = (CFDictionaryRef)CFArrayGetValueAtIndex(arr, 0);
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
    if (!spacesArr) { CFRelease(arr); return 1; }
    
    int result = 1;
    CFIndex nSpaces = CFArrayGetCount(spacesArr);
    for (CFIndex i = 0; i < nSpaces; i++) {
        CFDictionaryRef sDict = (CFDictionaryRef)CFArrayGetValueAtIndex(spacesArr, i);
        CFNumberRef sIdNum = (CFNumberRef)CFDictionaryGetValue(sDict, CFSTR("ManagedSpaceID"));
        long long sId = 0;
        if (sIdNum) CFNumberGetValue(sIdNum, kCFNumberLongLongType, &sId);
        if ((uint64_t)sId == curId) {
            result = (int)(i + 1);
            break;
        }
    }
    CFRelease(arr);
    return result;
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
    return NULL;
}

@interface SpaceSync : NSObject
- (void)syncWorkspace;
- (void)spaceChanged:(NSNotification *)note;
- (void)periodicTimer:(NSTimer *)timer;
@end

@implementation SpaceSync {
    int _lastSpace;
    char _jkkonfigBin[1024];
}

- (instancetype)initWithJkkonfig:(const char *)jkkonfig {
    if (self = [super init]) {
        _lastSpace = -1;
        if (jkkonfig) {
            strncpy(_jkkonfigBin, jkkonfig, sizeof(_jkkonfigBin) - 1);
        } else {
            const char *env = getenv("JKKONFIG_BIN");
            if (env && env[0]) {
                strncpy(_jkkonfigBin, env, sizeof(_jkkonfigBin) - 1);
            } else {
                const char *home = getenv("HOME");
                if (home) {
                    snprintf(_jkkonfigBin, sizeof(_jkkonfigBin), "%s/.config/jkkonfig/bin/jkkonfig", home);
                } else {
                    _jkkonfigBin[0] = '\0';
                }
            }
        }
        
        // Sofort synchronisieren
        [self syncWorkspace];
        
        [[[NSWorkspace sharedWorkspace] notificationCenter] addObserver:self
                                                               selector:@selector(spaceChanged:)
                                                                   name:NSWorkspaceActiveSpaceDidChangeNotification
                                                                 object:nil];
        [[[NSWorkspace sharedWorkspace] notificationCenter] addObserver:self
                                                               selector:@selector(spaceChanged:)
                                                                   name:NSWorkspaceDidActivateApplicationNotification
                                                                 object:nil];
        
        [NSTimer scheduledTimerWithTimeInterval:60.0
                                         target:self
                                       selector:@selector(periodicTimer:)
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

- (void)spaceChanged:(NSNotification *)note {
    [self syncWorkspace];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(50 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        [self syncWorkspace];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(150 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        [self syncWorkspace];
    });
}

- (void)periodicTimer:(NSTimer *)timer {
    if (_jkkonfigBin[0]) {
        char cmd[1200];
        snprintf(cmd, sizeof(cmd), "%s wachen >/dev/null 2>&1", _jkkonfigBin);
        system(cmd);
    }
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        void *sl = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY);
        if (sl) {
            getConn = (MainConnFunc)dlsym(sl, "SLSMainConnectionID");
            getActiveSpace = (ActiveSpaceFunc)dlsym(sl, "SLSGetActiveSpace");
            copySpaces = (CopySpacesFunc)dlsym(sl, "SLSCopyManagedDisplaySpaces");
        }
        
        if (argc > 1 && strcmp(argv[1], "--current") == 0) {
            printf("%d\n", get_current_space_index());
            return 0;
        }
        
        const char *jk = get_jkkonfig_path();
        if (!jk && argc > 1) jk = argv[1];
        
        SpaceSync *sync = [[SpaceSync alloc] initWithJkkonfig:jk];
        (void)sync;
        [[NSRunLoop currentRunLoop] run];
    }
    return 0;
}
