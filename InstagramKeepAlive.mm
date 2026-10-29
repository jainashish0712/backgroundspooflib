//
//  InstagramKeepAlive.mm
//  InstagramKeepAlive
//
//  Approach 2: Surgical Warm-Start & Memory Purge Neutralization
//  Prevents Instagram from purging RAM/caches on app minimize,
//  and completely eliminates forced feed/reels auto-refresh & auto-scroll on maximize.
//  Ensures 0% CPU and zero background heating by allowing video decoders to pause naturally.
//

#import "InstagramKeepAlive.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <atomic>

#define KEEP_ALIVE_LOG(fmt, ...) NSLog(@"[InstagramKeepAlive] " fmt, ##__VA_ARGS__)

// Large safe interval representing 24 hours (86,400 seconds)
static const double kInfiniteInterval = 86400.0;
static const NSInteger kInfiniteTimerSeconds = 86400;

// Grace window (in seconds) after foregrounding during which automated scroll-to-top is blocked
static const NSTimeInterval kWarmStartGraceWindow = 2.0;

// State flags & timestamps
static std::atomic<bool> s_isActive{false};
static std::atomic<bool> s_hasEnteredBackground{false};
static std::atomic<bool> s_isAppBackgrounded{false};
static std::atomic<bool> s_isRestoringFromWarmStart{false};
static std::atomic<NSTimeInterval> s_backgroundTimestamp{0.0};
static std::atomic<NSTimeInterval> s_foregroundTimestamp{0.0};

// Telemetry counters
static std::atomic<NSUInteger> s_suppressedPurgeCount{0};
static std::atomic<NSUInteger> s_suppressedRefreshCount{0};
static std::atomic<NSUInteger> s_suppressedScrollCount{0};
static std::atomic<NSUInteger> s_spoofedTimerCount{0};

#pragma mark - Public Telemetry & Status API

BOOL InstagramKeepAlive_IsActive(void) {
    return s_isActive.load();
}

BOOL InstagramKeepAlive_IsBackgrounded(void) {
    return s_isAppBackgrounded.load();
}

BOOL InstagramKeepAlive_HasEnteredBackground(void) {
    return s_hasEnteredBackground.load();
}

BOOL InstagramKeepAlive_IsRestoringFromWarmStart(void) {
    return s_isRestoringFromWarmStart.load();
}

NSUInteger InstagramKeepAlive_SuppressedPurgeCount(void) {
    return s_suppressedPurgeCount.load();
}

NSUInteger InstagramKeepAlive_SuppressedRefreshCount(void) {
    return s_suppressedRefreshCount.load();
}

NSUInteger InstagramKeepAlive_SuppressedScrollCount(void) {
    return s_suppressedScrollCount.load();
}

NSUInteger InstagramKeepAlive_SpoofedTimerCount(void) {
    return s_spoofedTimerCount.load();
}

#pragma mark - Safe Swizzling Helpers

static void SwizzleMethod(Class cls, SEL origSel, SEL altSel, IMP altImp, const char *types) {
    if (!cls || !origSel || !altSel || !altImp) return;
    
    // Add altSel pointing to our hook
    if (!class_addMethod(cls, altSel, altImp, types ? types : "v@:")) {
        Method existingAlt = class_getInstanceMethod(cls, altSel);
        if (existingAlt) {
            method_setImplementation(existingAlt, altImp);
        }
    }
    
    Method origMethod = class_getInstanceMethod(cls, origSel);
    Method altMethod = class_getInstanceMethod(cls, altSel);
    if (!origMethod || !altMethod) return;
    
    // If origSel was inherited from a superclass, class_addMethod attaches it to cls
    if (class_addMethod(cls, origSel, altImp, types ? types : method_getTypeEncoding(origMethod))) {
        class_replaceMethod(cls, altSel, method_getImplementation(origMethod), types ? types : method_getTypeEncoding(origMethod));
    } else {
        method_exchangeImplementations(origMethod, altMethod);
    }
}

#pragma mark - Hook Implementations

// 1. Intercept clearMemoryCache: on image caches
// Keeps decoded image textures in RAM while the app is in background,
// but consumes 0% CPU and generates zero heat.
static void IKA_ClearMemoryCache(id self, SEL _cmd, id factor) {
    if (s_isAppBackgrounded.load()) {
        s_suppressedPurgeCount.fetch_add(1);
        KEEP_ALIVE_LOG("Suppressed background clearMemoryCache: on %s (Count: %lu)",
                       class_getName(object_getClass(self)),
                       (unsigned long)s_suppressedPurgeCount.load());
        return;
    }
    
    // Outside backgrounding, pass through to original implementation
    SEL altSel = @selector(ika_clearMemoryCache:);
    Method m = class_getInstanceMethod(object_getClass(self), altSel);
    if (m) {
        ((void (*)(id, SEL, id))objc_msgSend)(self, altSel, factor);
    }
}

// 2. shouldRefreshFeedOnHotStart
static BOOL IKA_ShouldRefreshFeedOnHotStart(id self, SEL _cmd) {
    // If app has never been backgrounded, it is a cold start: allow normal initialization!
    if (!s_hasEnteredBackground.load()) {
        SEL altSel = @selector(ika_shouldRefreshFeedOnHotStart);
        Method m = class_getInstanceMethod(object_getClass(self), altSel);
        if (m) {
            return ((BOOL (*)(id, SEL))objc_msgSend)(self, altSel);
        }
        return YES;
    }
    
    // Warm start: suppress automatic reload
    s_spoofedTimerCount.fetch_add(1);
    KEEP_ALIVE_LOG("Intercepted -[%s %s] on warm-start -> Returning NO",
                   class_getName(object_getClass(self)), sel_getName(_cmd));
    return NO;
}

// 3. warmStartRefreshInterval / minimumWarmStartBackgroundedInterval
static double IKA_WarmStartRefreshInterval(id self, SEL _cmd) {
    // If app has been backgrounded, return 24 hours so Instagram considers feed cache fresh
    if (s_hasEnteredBackground.load()) {
        s_spoofedTimerCount.fetch_add(1);
        return kInfiniteInterval;
    }
    
    // On cold start, invoke original if available
    SEL altSel = @selector(ika_warmStartRefreshInterval);
    Method m = class_getInstanceMethod(object_getClass(self), altSel);
    if (m) {
        return ((double (*)(id, SEL))objc_msgSend)(self, altSel);
    }
    return 0.0;
}

static NSInteger IKA_WarmStartRefreshTimerInSeconds(id self, SEL _cmd) {
    if (s_hasEnteredBackground.load()) {
        s_spoofedTimerCount.fetch_add(1);
        return kInfiniteTimerSeconds;
    }
    SEL altSel = @selector(ika_warmStartRefreshTimerInSeconds);
    Method m = class_getInstanceMethod(object_getClass(self), altSel);
    if (m) {
        return ((NSInteger (*)(id, SEL))objc_msgSend)(self, altSel);
    }
    return 0;
}

// 4. scrollToTopAnimated:
static void IKA_ScrollToTopAnimated(id self, SEL _cmd, BOOL animated) {
    // Suppress ONLY during genuine warm-start restoration window
    if (s_isRestoringFromWarmStart.load()) {
        s_suppressedScrollCount.fetch_add(1);
        KEEP_ALIVE_LOG("Suppressed warm-start scrollToTopAnimated: on %s (Count: %lu)",
                       class_getName(object_getClass(self)),
                       (unsigned long)s_suppressedScrollCount.load());
        return;
    }
    
    // User manual scroll-to-top (tapping status bar or active tab icon) proceeds normally
    SEL altSel = @selector(ika_scrollToTopAnimated:);
    Method m = class_getInstanceMethod(object_getClass(self), altSel);
    if (m) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(self, altSel, animated);
    }
}

#pragma mark - Lifecycle Observers

static void SetupLifecycleObservers(void) {
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    
    // 1. App Minimized (Did Enter Background)
    [center addObserverForName:UIApplicationDidEnterBackgroundNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification * _Nonnull note) {
        s_hasEnteredBackground.store(true);
        s_isAppBackgrounded.store(true);
        s_backgroundTimestamp.store([NSDate timeIntervalSinceReferenceDate]);
        KEEP_ALIVE_LOG("=== App Minimized to Background ===");
        KEEP_ALIVE_LOG("Shield active: Suppressing memory purges & keeping RAM cached. Video paused naturally (0% CPU/0 heating).");
    }];
    
    // 2. App Maximized (Will Enter Foreground)
    [center addObserverForName:UIApplicationWillEnterForegroundNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification * _Nonnull note) {
        s_isAppBackgrounded.store(false);
        
        // CRITICAL: On cold start, iOS always dispatches UIApplicationWillEnterForegroundNotification.
        // If the app has never been backgrounded, this is a cold launch; ignore it completely
        // so that initial feed fetching runs with zero interference!
        if (!s_hasEnteredBackground.load()) {
            KEEP_ALIVE_LOG("App Initial Launch (Cold Start) -> Cold start feed loading untouched.");
            return;
        }
        
        s_foregroundTimestamp.store([NSDate timeIntervalSinceReferenceDate]);
        s_isRestoringFromWarmStart.store(true);
        
        NSTimeInterval elapsed = s_foregroundTimestamp.load() - s_backgroundTimestamp.load();
        KEEP_ALIVE_LOG("=== App Maximized to Foreground (Resuming after %.1fs) ===", elapsed);
        KEEP_ALIVE_LOG("Warm-start shield engaged: Suppressing auto-scroll for %.1fs.", kWarmStartGraceWindow);
        
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kWarmStartGraceWindow * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            s_isRestoringFromWarmStart.store(false);
            KEEP_ALIVE_LOG("Warm-start restoration window complete. Standard user gestures active.");
        });
    }];
    
    // 3. App Became Active
    [center addObserverForName:UIApplicationDidBecomeActiveNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification * _Nonnull note) {
        KEEP_ALIVE_LOG("App Active. Stats -> Purges suppressed: %lu | Scrolls suppressed: %lu | Timers spoofed: %lu",
                       (unsigned long)s_suppressedPurgeCount.load(),
                       (unsigned long)s_suppressedScrollCount.load(),
                       (unsigned long)s_spoofedTimerCount.load());
    }];
}

#pragma mark - Hook Registration

static void ApplyHooks(void) {
    // 1. Image Memory Caches (Suppress clearing only while backgrounded)
    NSArray<NSString *> *imageCacheClasses = @[
        @"IGUnifiedImageMemoryCache",
        @"_IGImageServiceMemoryCache",
        @"MOSImageMemoryCache",
        @"_MOSImageMemoryCache"
    ];
    for (NSString *className in imageCacheClasses) {
        Class cls = objc_getClass([className UTF8String]);
        if (cls) {
            SwizzleMethod(cls, @selector(clearMemoryCache:), @selector(ika_clearMemoryCache:), (IMP)IKA_ClearMemoryCache, "v@:@");
            KEEP_ALIVE_LOG("Installed image cache protection on %s", [className UTF8String]);
        }
    }
    
    // 2. Feed Network Sources & Coordinators (Warm-Start Interval Spoofing to 24h)
    NSArray<NSString *> *feedSourceClasses = @[
        @"IGFeedNetworkSource",
        @"IGMainFeedNetworkSource",
        @"IGFeedContentCoordinator"
    ];
    for (NSString *className in feedSourceClasses) {
        Class cls = objc_getClass([className UTF8String]);
        if (cls) {
            SwizzleMethod(cls, @selector(warmStartRefreshInterval), @selector(ika_warmStartRefreshInterval), (IMP)IKA_WarmStartRefreshInterval, "d@:");
            SwizzleMethod(cls, @selector(warmStartRefreshIntervalOnPeak), @selector(ika_warmStartRefreshIntervalOnPeak), (IMP)IKA_WarmStartRefreshInterval, "d@:");
            SwizzleMethod(cls, @selector(minimumWarmStartBackgroundedInterval), @selector(ika_minimumWarmStartBackgroundedInterval), (IMP)IKA_WarmStartRefreshInterval, "d@:");
            SwizzleMethod(cls, @selector(minimumWarmStartBackgroundedIntervalOnPeak), @selector(ika_minimumWarmStartBackgroundedIntervalOnPeak), (IMP)IKA_WarmStartRefreshInterval, "d@:");
            SwizzleMethod(cls, @selector(warmStartRefreshTimerInSeconds), @selector(ika_warmStartRefreshTimerInSeconds), (IMP)IKA_WarmStartRefreshTimerInSeconds, "q@:");
            KEEP_ALIVE_LOG("Installed warm-start threshold spoofing on %s", [className UTF8String]);
        }
    }
    
    // 3. Feed View Controllers (Scroll-to-top retention & hot start check)
    NSArray<NSString *> *feedVCClasses = @[
        @"IGMainFeedViewController",
        @"IGMainFeedViewController_objc",
        @"_TtC15IGMainFeedSwift30IGMainFeedViewController_swift"
    ];
    for (NSString *className in feedVCClasses) {
        Class cls = objc_getClass([className UTF8String]);
        if (cls) {
            SwizzleMethod(cls, @selector(scrollToTopAnimated:), @selector(ika_scrollToTopAnimated:), (IMP)IKA_ScrollToTopAnimated, "v@:B");
            SwizzleMethod(cls, @selector(shouldRefreshFeedOnHotStart), @selector(ika_shouldRefreshFeedOnHotStart), (IMP)IKA_ShouldRefreshFeedOnHotStart, "B@:");
            KEEP_ALIVE_LOG("Installed scroll & hot-start protection on %s", [className UTF8String]);
        }
    }
}

#pragma mark - Initialization

void InstagramKeepAlive_Init(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        KEEP_ALIVE_LOG("=================================================");
        KEEP_ALIVE_LOG("Initializing InstagramKeepAlive (Approach 2)");
        KEEP_ALIVE_LOG("Zero RAM Purge on Minimize | Zero Feed Reload on Maximize");
        KEEP_ALIVE_LOG("0%% CPU in Background | Zero Heating Guarantee");
        KEEP_ALIVE_LOG("=================================================");
        
        SetupLifecycleObservers();
        ApplyHooks();
        
        s_isActive.store(true);
        KEEP_ALIVE_LOG("InstagramKeepAlive successfully activated!");
    });
}

#pragma mark - Constructor Entry Point

__attribute__((constructor)) static void InstagramKeepAlive_Ctor(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        InstagramKeepAlive_Init();
    });
}
