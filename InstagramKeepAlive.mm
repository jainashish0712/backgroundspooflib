//
//  InstagramKeepAlive.mm
//  InstagramKeepAlive
//
//  Approach 2: Surgical Warm-Start & Memory Purge Neutralization
//  Prevents Instagram from purging RAM/caches on app minimize,
//  and completely eliminates forced feed/reels auto-refresh & auto-scroll on maximize.
//

#import "InstagramKeepAlive.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <atomic>

#define KEEP_ALIVE_LOG(fmt, ...) NSLog(@"[InstagramKeepAlive] " fmt, ##__VA_ARGS__)

// Large safe interval representing ~1000 days (effectively infinite threshold)
static const double kInfiniteInterval = 86400000.0;
static const NSInteger kInfiniteTimerSeconds = 86400000;

// Grace window (in seconds) after foregrounding during which automated reloads & scrolls are blocked
static const NSTimeInterval kWarmStartGraceWindow = 2.0;

// State flags & timestamps
static std::atomic<bool> s_isActive{false};
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

#pragma mark - Method Swizzling Helpers

static BOOL SwizzleMethodWithOriginal(Class cls, SEL origSel, IMP newImp, IMP *outOrigImp) {
    if (!cls || !origSel || !newImp) return NO;
    
    Method method = class_getInstanceMethod(cls, origSel);
    if (!method) {
        // Method doesn't exist on this class
        return NO;
    }
    
    IMP orig = method_getImplementation(method);
    if (outOrigImp) {
        *outOrigImp = orig;
    }
    
    const char *types = method_getTypeEncoding(method);
    // If method is inherited from a superclass, class_addMethod attaches our implementation directly to cls
    if (class_addMethod(cls, origSel, newImp, types)) {
        // Re-get the method on cls and ensure original pointer is preserved
        return YES;
    } else {
        // Method already directly implemented on cls, replace its implementation
        method_setImplementation(method, newImp);
        return YES;
    }
}

static BOOL ReplaceMethodAlways(Class cls, SEL sel, IMP newImp, const char *types) {
    if (!cls || !sel || !newImp) return NO;
    
    Method method = class_getInstanceMethod(cls, sel);
    if (method) {
        method_setImplementation(method, newImp);
        return YES;
    } else {
        return class_addMethod(cls, sel, newImp, types ? types : "v@:");
    }
}

#pragma mark - Category A: Memory Purge Neutralization Replacements

// 1. Generic safe NO-OP implementation for background purge methods
static void Hook_PurgeNoOp(id self, SEL _cmd) {
    s_suppressedPurgeCount.fetch_add(1);
    KEEP_ALIVE_LOG("Suppressed memory purge: -[%s %s] (Purge count: %lu)",
                   class_getName(object_getClass(self)), sel_getName(_cmd),
                   (unsigned long)s_suppressedPurgeCount.load());
}

static void Hook_PurgeNoOp_WithArg(id self, SEL _cmd, id arg) {
    s_suppressedPurgeCount.fetch_add(1);
    KEEP_ALIVE_LOG("Suppressed memory purge: -[%s %s] with arg %s (Purge count: %lu)",
                   class_getName(object_getClass(self)), sel_getName(_cmd),
                   arg ? class_getName(object_getClass(arg)) : "nil",
                   (unsigned long)s_suppressedPurgeCount.load());
}

// 2. Cache clearing interception
typedef void (*ClearMemoryCacheOrigFunc)(id self, SEL _cmd, id factor);
static ClearMemoryCacheOrigFunc s_orig_clearMemoryCache_factor = NULL;

static void Hook_ClearMemoryCache(id self, SEL _cmd, id factor) {
    // If the app is currently in background or transitioning to background, suppress cache clearing
    if (s_isAppBackgrounded.load()) {
        s_suppressedPurgeCount.fetch_add(1);
        KEEP_ALIVE_LOG("Suppressed background cache clear: -[%s %s] (Purge count: %lu)",
                       class_getName(object_getClass(self)), sel_getName(_cmd),
                       (unsigned long)s_suppressedPurgeCount.load());
        return;
    }
    // Outside backgrounding, pass through to original
    if (s_orig_clearMemoryCache_factor) {
        s_orig_clearMemoryCache_factor(self, _cmd, factor);
    }
}

#pragma mark - Category B: Warm Start Timers & Triggers Replacements

// 1. shouldRefreshFeedOnHotStart -> Always return NO
static BOOL Hook_ShouldRefreshFeedOnHotStart(id self, SEL _cmd) {
    s_spoofedTimerCount.fetch_add(1);
    KEEP_ALIVE_LOG("Intercepted -[%s %s] -> Returning NO",
                   class_getName(object_getClass(self)), sel_getName(_cmd));
    return NO;
}

// 2. warmStartRefreshInterval / warmStartRefreshIntervalOnPeak / minimumWarmStartBackgroundedInterval -> Return infinite interval
static double Hook_WarmStartRefreshInterval(id self, SEL _cmd) {
    s_spoofedTimerCount.fetch_add(1);
    KEEP_ALIVE_LOG("Intercepted -[%s %s] -> Returning infinite interval (%.0f s)",
                   class_getName(object_getClass(self)), sel_getName(_cmd), kInfiniteInterval);
    return kInfiniteInterval;
}

static double Hook_WarmStartRefreshInterval_WithArgs(id self, SEL _cmd, id arg1, id arg2) {
    s_spoofedTimerCount.fetch_add(1);
    KEEP_ALIVE_LOG("Intercepted -[%s %s] -> Returning infinite interval (%.0f s)",
                   class_getName(object_getClass(self)), sel_getName(_cmd), kInfiniteInterval);
    return kInfiniteInterval;
}

// 3. warmStartRefreshTimerInSeconds -> Return large integer seconds
static NSInteger Hook_WarmStartRefreshTimerInSeconds(id self, SEL _cmd) {
    s_spoofedTimerCount.fetch_add(1);
    KEEP_ALIVE_LOG("Intercepted -[%s %s] -> Returning %ld s",
                   class_getName(object_getClass(self)), sel_getName(_cmd), (long)kInfiniteTimerSeconds);
    return kInfiniteTimerSeconds;
}

// 4. _timeSinceBackground -> Return 0.0s (Instagram thinks 0 seconds elapsed in background)
static double Hook_TimeSinceBackground(id self, SEL _cmd) {
    s_spoofedTimerCount.fetch_add(1);
    KEEP_ALIVE_LOG("Intercepted -[%s %s] -> Returning 0.0s",
                   class_getName(object_getClass(self)), sel_getName(_cmd));
    return 0.0;
}

// 5. didEnterBackgroundDate / lastDidEnterBackgroundDate -> Return current date so diff is 0.0s
static NSDate *Hook_DidEnterBackgroundDate(id self, SEL _cmd) {
    s_spoofedTimerCount.fetch_add(1);
    KEEP_ALIVE_LOG("Intercepted -[%s %s] -> Returning [NSDate date] (diff = 0.0s)",
                   class_getName(object_getClass(self)), sel_getName(_cmd));
    return [NSDate date];
}

#pragma mark - Category C: Auto-Scroll & Viewport Retention Replacements

// 1. scrollToTopAnimated:
typedef void (*ScrollToTopOrigFunc)(id self, SEL _cmd, BOOL animated);
static ScrollToTopOrigFunc s_orig_scrollToTopAnimated = NULL;

static void Hook_ScrollToTopAnimated(id self, SEL _cmd, BOOL animated) {
    // If the app is currently in the warm-start restoration window, suppress auto-scroll
    if (s_isRestoringFromWarmStart.load()) {
        s_suppressedScrollCount.fetch_add(1);
        KEEP_ALIVE_LOG("Suppressed warm-start scrollToTopAnimated: on %s (Scroll count: %lu)",
                       class_getName(object_getClass(self)),
                       (unsigned long)s_suppressedScrollCount.load());
        return;
    }
    
    // User explicitly tapped status bar or scrolled manually, call original
    if (s_orig_scrollToTopAnimated) {
        s_orig_scrollToTopAnimated(self, _cmd, animated);
    }
}

// 2. refreshFeedWithFetchReason:animated:
typedef void (*RefreshFeedOrigFunc)(id self, SEL _cmd, NSInteger reason, BOOL animated);
static RefreshFeedOrigFunc s_orig_refreshFeedWithFetchReason = NULL;

static void Hook_RefreshFeedWithFetchReason(id self, SEL _cmd, NSInteger reason, BOOL animated) {
    // If restoring from warm start, suppress automatic background/warm-start feed refresh
    if (s_isRestoringFromWarmStart.load()) {
        s_suppressedRefreshCount.fetch_add(1);
        KEEP_ALIVE_LOG("Suppressed warm-start feed reload: -[%s %s reason:%ld animated:%d] (Refresh count: %lu)",
                       class_getName(object_getClass(self)), sel_getName(_cmd),
                       (long)reason, animated,
                       (unsigned long)s_suppressedRefreshCount.load());
        return;
    }
    
    // Normal user-initiated pull-to-refresh or explicit refresh
    if (s_orig_refreshFeedWithFetchReason) {
        s_orig_refreshFeedWithFetchReason(self, _cmd, reason, animated);
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
        s_isAppBackgrounded.store(true);
        s_backgroundTimestamp.store([NSDate timeIntervalSinceReferenceDate]);
        KEEP_ALIVE_LOG("=== App Minimized to Background ===");
        KEEP_ALIVE_LOG("Shield active: Suppressing memory purges & keeping all posts/reels cached in RAM.");
    }];
    
    // 2. App Maximized (Will Enter Foreground)
    [center addObserverForName:UIApplicationWillEnterForegroundNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification * _Nonnull note) {
        s_isAppBackgrounded.store(false);
        s_foregroundTimestamp.store([NSDate timeIntervalSinceReferenceDate]);
        s_isRestoringFromWarmStart.store(true);
        
        NSTimeInterval elapsed = s_foregroundTimestamp.load() - s_backgroundTimestamp.load();
        KEEP_ALIVE_LOG("=== App Maximized to Foreground (Resuming after %.1fs) ===", elapsed);
        KEEP_ALIVE_LOG("Warm-start shield engaged: Neutralizing auto-refresh & auto-scroll for %.1fs.", kWarmStartGraceWindow);
        
        // After grace period, allow manual user refreshes and scroll-to-top actions
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kWarmStartGraceWindow * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            s_isRestoringFromWarmStart.store(false);
            KEEP_ALIVE_LOG("Warm-start restoration window complete. Standard user gestures restored.");
        });
    }];
    
    // 3. App Became Active
    [center addObserverForName:UIApplicationDidBecomeActiveNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification * _Nonnull note) {
        KEEP_ALIVE_LOG("App Active. Current stats -> Purges suppressed: %lu | Refreshes suppressed: %lu | Scrolls suppressed: %lu | Timers spoofed: %lu",
                       (unsigned long)s_suppressedPurgeCount.load(),
                       (unsigned long)s_suppressedRefreshCount.load(),
                       (unsigned long)s_suppressedScrollCount.load(),
                       (unsigned long)s_spoofedTimerCount.load());
    }];
}

#pragma mark - Dynamic Swizzling & Class Discovery

static void ApplyDirectHooks(void) {
    // 1. IGHomeSundialFeedStoriesManager (Stories + Reels Manager)
    NSArray<NSString *> *sundialClasses = @[
        @"IGHomeSundialFeedStoriesManager",
        @"_TtC17IGHomeSundialFeed31IGHomeSundialFeedStoriesManager"
    ];
    for (NSString *className in sundialClasses) {
        Class cls = objc_getClass([className UTF8String]);
        if (cls) {
            ReplaceMethodAlways(cls, @selector(ios_purge_26_q2_IGHomeSundialFeedStoriesManager_handleAppDidEnterBackground), (IMP)Hook_PurgeNoOp, "v@:");
            ReplaceMethodAlways(cls, @selector(handleAppDidEnterBackground), (IMP)Hook_PurgeNoOp, "v@:");
            KEEP_ALIVE_LOG("Hooked purge methods on %s", [className UTF8String]);
        }
    }
    
    // 2. Secondary feed/reels controllers with background purges
    NSArray<NSString *> *purgeClasses = @[
        @"IGMetaAIReelsMidcardSectionController",
        @"IGShortDramaSeriesPageViewController",
        @"IGDirectVoiceRecordViewController",
        @"IGCountdownTimerPickerV2ViewController",
        @"IGCutoutMaskLoader"
    ];
    for (NSString *className in purgeClasses) {
        Class cls = objc_getClass([className UTF8String]);
        if (cls) {
            ReplaceMethodAlways(cls, @selector(ios_purge_26_q3_IGMetaAIReelsMidcardSectionController_handleDidEnterBackground), (IMP)Hook_PurgeNoOp, "v@:");
            ReplaceMethodAlways(cls, @selector(ios_purge_26_q3_IGShortDramaSeriesPageViewController_handleDidEnterBackground), (IMP)Hook_PurgeNoOp, "v@:");
            ReplaceMethodAlways(cls, @selector(ios_purge_26_q2_IGDirectVoiceRecordViewController_applicationDidEnterBackground), (IMP)Hook_PurgeNoOp, "v@:");
            ReplaceMethodAlways(cls, @selector(ios_purge_26_q3_IGCountdownTimerPickerV2ViewController_applicationDidEnterBackground), (IMP)Hook_PurgeNoOp, "v@:");
            ReplaceMethodAlways(cls, @selector(ios_purge_26_q3_IGCutoutMaskLoader_appDidEnterBackground), (IMP)Hook_PurgeNoOp, "v@:");
            ReplaceMethodAlways(cls, @selector(handleDidEnterBackground), (IMP)Hook_PurgeNoOp, "v@:");
        }
    }
    
    // 3. Image Memory Caches (IGUnifiedImageMemoryCache, _IGImageServiceMemoryCache, MOSImageMemoryCache)
    NSArray<NSString *> *imageCacheClasses = @[
        @"IGUnifiedImageMemoryCache",
        @"_IGImageServiceMemoryCache",
        @"_MOSImageMemoryCache",
        @"MOSImageMemoryCache"
    ];
    for (NSString *className in imageCacheClasses) {
        Class cls = objc_getClass([className UTF8String]);
        if (cls) {
            SEL selClearFactor = @selector(clearMemoryCache:);
            IMP origImp = NULL;
            if (SwizzleMethodWithOriginal(cls, selClearFactor, (IMP)Hook_ClearMemoryCache, &origImp)) {
                if (!s_orig_clearMemoryCache_factor) {
                    s_orig_clearMemoryCache_factor = (ClearMemoryCacheOrigFunc)origImp;
                }
                KEEP_ALIVE_LOG("Hooked clearMemoryCache: on %s", [className UTF8String]);
            }
            ReplaceMethodAlways(cls, @selector(clearInMemoryCache), (IMP)Hook_PurgeNoOp, "v@:");
            ReplaceMethodAlways(cls, @selector(clearInnerMemoryCache), (IMP)Hook_PurgeNoOp, "v@:");
        }
    }
    
    // 4. Main Feed View Controllers (IGMainFeedViewController_objc, IGMainFeedViewController_swift)
    NSArray<NSString *> *feedVCClasses = @[
        @"IGMainFeedViewController",
        @"IGMainFeedViewController_objc",
        @"_TtC15IGMainFeedSwift30IGMainFeedViewController_swift"
    ];
    for (NSString *className in feedVCClasses) {
        Class cls = objc_getClass([className UTF8String]);
        if (cls) {
            // Hot start refresh flag
            ReplaceMethodAlways(cls, @selector(shouldRefreshFeedOnHotStart), (IMP)Hook_ShouldRefreshFeedOnHotStart, "B@:");
            
            // Scroll to top
            SEL selScroll = @selector(scrollToTopAnimated:);
            IMP origScrollImp = NULL;
            if (SwizzleMethodWithOriginal(cls, selScroll, (IMP)Hook_ScrollToTopAnimated, &origScrollImp)) {
                if (!s_orig_scrollToTopAnimated) {
                    s_orig_scrollToTopAnimated = (ScrollToTopOrigFunc)origScrollImp;
                }
                KEEP_ALIVE_LOG("Hooked scrollToTopAnimated: on %s", [className UTF8String]);
            }
            
            // Feed refresh with fetch reason
            SEL selRefresh = @selector(refreshFeedWithFetchReason:animated:);
            IMP origRefreshImp = NULL;
            if (SwizzleMethodWithOriginal(cls, selRefresh, (IMP)Hook_RefreshFeedWithFetchReason, &origRefreshImp)) {
                if (!s_orig_refreshFeedWithFetchReason) {
                    s_orig_refreshFeedWithFetchReason = (RefreshFeedOrigFunc)origRefreshImp;
                }
                KEEP_ALIVE_LOG("Hooked refreshFeedWithFetchReason:animated: on %s", [className UTF8String]);
            }
            
            ReplaceMethodAlways(cls, @selector(feedDidEnterBackground), (IMP)Hook_PurgeNoOp, "v@:");
            ReplaceMethodAlways(cls, @selector(resetOnDidEnterBackground), (IMP)Hook_PurgeNoOp, "v@:");
        }
    }
}

static void ApplyDynamicClassDiscovery(void) {
    int numClasses = objc_getClassList(NULL, 0);
    if (numClasses <= 0) return;
    
    Class *classes = (Class *)malloc(sizeof(Class) * numClasses);
    if (!classes) return;
    
    numClasses = objc_getClassList(classes, numClasses);
    NSUInteger hookedTimerClasses = 0;
    
    for (int i = 0; i < numClasses; i++) {
        Class cls = classes[i];
        if (!cls) continue;
        
        const char *name = class_getName(cls);
        if (!name) continue;
        
        // Target IG and Meta framework classes
        if (strncmp(name, "IG", 2) != 0 && strncmp(name, "_TtC", 4) != 0 && strncmp(name, "FB", 2) != 0 && strncmp(name, "MOS", 3) != 0) {
            continue;
        }
        
        // 1. shouldRefreshFeedOnHotStart
        if (class_getInstanceMethod(cls, @selector(shouldRefreshFeedOnHotStart))) {
            ReplaceMethodAlways(cls, @selector(shouldRefreshFeedOnHotStart), (IMP)Hook_ShouldRefreshFeedOnHotStart, "B@:");
            hookedTimerClasses++;
        }
        
        // 2. warmStartRefreshInterval
        if (class_getInstanceMethod(cls, @selector(warmStartRefreshInterval))) {
            ReplaceMethodAlways(cls, @selector(warmStartRefreshInterval), (IMP)Hook_WarmStartRefreshInterval, "d@:");
            hookedTimerClasses++;
        }
        
        // 3. warmStartRefreshIntervalOnPeak
        if (class_getInstanceMethod(cls, @selector(warmStartRefreshIntervalOnPeak))) {
            ReplaceMethodAlways(cls, @selector(warmStartRefreshIntervalOnPeak), (IMP)Hook_WarmStartRefreshInterval, "d@:");
            hookedTimerClasses++;
        }
        
        // 4. minimumWarmStartBackgroundedInterval
        if (class_getInstanceMethod(cls, @selector(minimumWarmStartBackgroundedInterval))) {
            ReplaceMethodAlways(cls, @selector(minimumWarmStartBackgroundedInterval), (IMP)Hook_WarmStartRefreshInterval, "d@:");
            hookedTimerClasses++;
        }
        
        // 5. minimumWarmStartBackgroundedIntervalOnPeak
        if (class_getInstanceMethod(cls, @selector(minimumWarmStartBackgroundedIntervalOnPeak))) {
            ReplaceMethodAlways(cls, @selector(minimumWarmStartBackgroundedIntervalOnPeak), (IMP)Hook_WarmStartRefreshInterval, "d@:");
            hookedTimerClasses++;
        }
        
        // 6. warmStartBackgroundRefreshIntervalWithLauncherSet:feedRefreshInstructionsStore:
        SEL selWarmBg = @selector(warmStartBackgroundRefreshIntervalWithLauncherSet:feedRefreshInstructionsStore:);
        if (class_getInstanceMethod(cls, selWarmBg)) {
            ReplaceMethodAlways(cls, selWarmBg, (IMP)Hook_WarmStartRefreshInterval_WithArgs, "d@:@@");
            hookedTimerClasses++;
        }
        
        // 7. warmStartRefreshIntervalWithLauncherSet:feedRefreshInstructionsStore:
        SEL selWarmRefresh = @selector(warmStartRefreshIntervalWithLauncherSet:feedRefreshInstructionsStore:);
        if (class_getInstanceMethod(cls, selWarmRefresh)) {
            ReplaceMethodAlways(cls, selWarmRefresh, (IMP)Hook_WarmStartRefreshInterval_WithArgs, "d@:@@");
            hookedTimerClasses++;
        }
        
        // 8. warmStartRefreshTimerInSeconds
        if (class_getInstanceMethod(cls, @selector(warmStartRefreshTimerInSeconds))) {
            ReplaceMethodAlways(cls, @selector(warmStartRefreshTimerInSeconds), (IMP)Hook_WarmStartRefreshTimerInSeconds, "q@:");
            hookedTimerClasses++;
        }
        
        // 9. _timeSinceBackground
        if (class_getInstanceMethod(cls, @selector(_timeSinceBackground))) {
            ReplaceMethodAlways(cls, @selector(_timeSinceBackground), (IMP)Hook_TimeSinceBackground, "d@:");
            hookedTimerClasses++;
        }
        
        // 10. didEnterBackgroundDate / lastDidEnterBackgroundDate
        if (class_getInstanceMethod(cls, @selector(didEnterBackgroundDate))) {
            ReplaceMethodAlways(cls, @selector(didEnterBackgroundDate), (IMP)Hook_DidEnterBackgroundDate, "@@:");
            hookedTimerClasses++;
        }
        if (class_getInstanceMethod(cls, @selector(lastDidEnterBackgroundDate))) {
            ReplaceMethodAlways(cls, @selector(lastDidEnterBackgroundDate), (IMP)Hook_DidEnterBackgroundDate, "@@:");
            hookedTimerClasses++;
        }
    }
    
    free(classes);
    KEEP_ALIVE_LOG("Dynamic class discovery completed. Attached warm-start/timer shields to %lu classes.",
                   (unsigned long)hookedTimerClasses);
}

#pragma mark - Initialization

void InstagramKeepAlive_Init(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        KEEP_ALIVE_LOG("=================================================");
        KEEP_ALIVE_LOG("Initializing InstagramKeepAlive (Approach 2)");
        KEEP_ALIVE_LOG("Zero RAM Purge on Minimize | Zero Feed Reload on Maximize");
        KEEP_ALIVE_LOG("=================================================");
        
        // 1. Setup notification observers for minimize & maximize
        SetupLifecycleObservers();
        
        // 2. Apply direct hooks on known core classes
        ApplyDirectHooks();
        
        // 3. Apply dynamic class discovery across all loaded frameworks
        ApplyDynamicClassDiscovery();
        
        s_isActive.store(true);
        KEEP_ALIVE_LOG("InstagramKeepAlive successfully activated!");
    });
}

#pragma mark - Constructor Entry Point

__attribute__((constructor)) static void InstagramKeepAlive_Ctor(void) {
    // Delay initialization slightly to ensure all Mach-O frameworks (FBSharedFramework, etc.) are loaded
    dispatch_async(dispatch_get_main_queue(), ^{
        InstagramKeepAlive_Init();
    });
}
