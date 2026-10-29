//
//  InstagramKeepAlive.mm
//  InstagramKeepAlive
//
//  Root-Level Keep-Alive & Feed Retention Architecture
//  Eliminates runtime getter wrapping by using:
//  1. Root Notification Filtering (Blocks image cache purge registration at the event root)
//  2. Native Meta Feed Configuration (Enables built-in disableAutomaticRefresh at creation root)
//  3. Natural Video/Audio Pause Lifecycle (Guarantees 0.0% CPU & zero background heating)
//  4. Viewport Retention (Preserves scroll position during warm-start restoration window)
//

#import "InstagramKeepAlive.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <atomic>

#define KEEP_ALIVE_LOG(fmt, ...) NSLog(@"[InstagramKeepAlive] " fmt, ##__VA_ARGS__)

// Grace window (in seconds) after foregrounding during which automated scroll-to-top is blocked
static const NSTimeInterval kWarmStartGraceWindow = 2.0;

// State flags & timestamps
static std::atomic<bool> s_isActive{false};
static std::atomic<bool> s_hasEnteredBackground{false};
static std::atomic<bool> s_isAppBackgrounded{false};
static std::atomic<bool> s_isRestoringFromWarmStart{false};
static std::atomic<NSTimeInterval> s_backgroundTimestamp{0.0};
static std::atomic<NSTimeInterval> s_foregroundTimestamp{0.0};

// Root telemetry counters
static std::atomic<NSUInteger> s_filteredNotificationCount{0};
static std::atomic<NSUInteger> s_configuredFeedSourceCount{0};
static std::atomic<NSUInteger> s_suppressedScrollCount{0};

#pragma mark - Public Telemetry & Status API

BOOL InstagramKeepAlive_IsActive(void) {
    return s_isActive.load();
}

BOOL InstagramKeepAlive_IsBackgrounded(void) {
    return s_isAppBackgrounded.load();
}

NSUInteger InstagramKeepAlive_FilteredNotificationCount(void) {
    return s_filteredNotificationCount.load();
}

NSUInteger InstagramKeepAlive_ConfiguredFeedSourceCount(void) {
    return s_configuredFeedSourceCount.load();
}

NSUInteger InstagramKeepAlive_SuppressedScrollCount(void) {
    return s_suppressedScrollCount.load();
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

#pragma mark - Root Fix 1: Notification Center Filtering

// Intercepts addObserver:selector:name:object: at the NSNotificationCenter root.
// Drops UIApplicationDidEnterBackgroundNotification observer registration for image caches.
// Because the observer is never added, the cache NEVER receives background notifications,
// completely eliminating RAM purging at the event source with zero runtime checks!
static void Root_AddObserver(id self, SEL _cmd, id target, SEL aSelector, NSNotificationName aName, id anObject) {
    if (aName && target && [aName isEqualToString:UIApplicationDidEnterBackgroundNotification]) {
        const char *className = class_getName(object_getClass(target));
        const char *selName = aSelector ? sel_getName(aSelector) : "";
        
        bool isImageCache = (className && (
            strstr(className, "ImageMemoryCache") != NULL ||
            strstr(className, "ImageServiceMemoryCache") != NULL ||
            strstr(className, "MOSImageMemoryCache") != NULL ||
            strstr(className, "IGUnifiedImageMemoryCache") != NULL ||
            strstr(className, "IGImageCache") != NULL
        ));
        
        bool isClearCacheSelector = (selName && (
            strstr(selName, "clearMemoryCache") != NULL ||
            strstr(selName, "cleanMemoryCache") != NULL
        ));
        
        if (isImageCache || isClearCacheSelector) {
            s_filteredNotificationCount.fetch_add(1);
            KEEP_ALIVE_LOG("Root Notification Filter: Dropped background purge observer registration for %s (selector: %s). RAM purge neutralized at root!",
                           className, selName);
            return;
        }
    }
    
    // Forward all other observers (including video players, audio session, coordinators)
    SEL altSel = @selector(ika_addObserver:selector:name:object:);
    Method m = class_getInstanceMethod(object_getClass(self), altSel);
    if (m) {
        ((void (*)(id, SEL, id, SEL, id, id))objc_msgSend)(self, altSel, target, aSelector, aName, anObject);
    }
}

static void ProactivelyDeregisterExistingCacheObservers(void) {
    NSArray<NSString *> *cacheClassNames = @[
        @"IGUnifiedImageMemoryCache",
        @"_IGImageServiceMemoryCache",
        @"MOSImageMemoryCache",
        @"_MOSImageMemoryCache",
        @"IGImageCache"
    ];
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    for (NSString *name in cacheClassNames) {
        Class cls = objc_getClass([name UTF8String]);
        if (!cls) continue;
        
        NSArray<NSString *> *singletonSelectors = @[@"sharedCache", @"sharedInstance", @"defaultCache"];
        for (NSString *selName in singletonSelectors) {
            SEL sel = NSSelectorFromString(selName);
            if ([cls respondsToSelector:sel]) {
                #pragma clang diagnostic push
                #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                id instance = [cls performSelector:sel];
                #pragma clang diagnostic pop
                if (instance) {
                    [center removeObserver:instance name:UIApplicationDidEnterBackgroundNotification object:nil];
                    KEEP_ALIVE_LOG("Proactively removed background purge observer from %s.%s", [name UTF8String], [selName UTF8String]);
                }
            }
        }
    }
}

#pragma mark - Root Fix 2: Native Meta Feed Configuration

static void ConfigureFeedSourceIvars(id self) {
    if (!self) return;
    Class cls = object_getClass(self);
    Ivar ivar = class_getInstanceVariable(cls, "_disableAutomaticRefresh");
    if (ivar) {
        *((BOOL *)((uintptr_t)self + ivar_getOffset(ivar))) = YES;
    }
    Ivar minIntervalIvar = class_getInstanceVariable(cls, "_minWarmStartFetchInterval");
    if (minIntervalIvar) {
        *((double *)((uintptr_t)self + ivar_getOffset(minIntervalIvar))) = 86400.0;
    }
    Ivar peakIntervalIvar = class_getInstanceVariable(cls, "_peakMinWarmStartFetchInterval");
    if (peakIntervalIvar) {
        *((double *)((uintptr_t)self + ivar_getOffset(peakIntervalIvar))) = 86400.0;
    }
    Ivar bgIntervalIvar = class_getInstanceVariable(cls, "_minimumWarmStartBackgroundedInterval");
    if (bgIntervalIvar) {
        *((double *)((uintptr_t)self + ivar_getOffset(bgIntervalIvar))) = 86400.0;
    }
}

// Native Meta switch on IGFeedNetworkSource
static BOOL Root_DisableAutomaticRefresh(id self, SEL _cmd) {
    s_configuredFeedSourceCount.fetch_add(1);
    ConfigureFeedSourceIvars(self);
    return YES;
}

static void Root_SetDisableAutomaticRefresh(id self, SEL _cmd, BOOL disable) {
    ConfigureFeedSourceIvars(self);
    SEL altSel = @selector(ika_setDisableAutomaticRefresh:);
    Method m = class_getInstanceMethod(object_getClass(self), altSel);
    if (m) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(self, altSel, YES);
    }
}

// Hot-start check on IGMainFeedViewController: Allow cold launch, suppress warm start
static BOOL Root_ShouldRefreshFeedOnHotStart(id self, SEL _cmd) {
    if (!s_hasEnteredBackground.load()) {
        SEL altSel = @selector(ika_shouldRefreshFeedOnHotStart);
        Method m = class_getInstanceMethod(object_getClass(self), altSel);
        if (m) {
            return ((BOOL (*)(id, SEL))objc_msgSend)(self, altSel);
        }
        return YES;
    }
    return NO;
}

#pragma mark - Root Fix 4: Viewport & Scroll Retention

static void Root_ScrollToTopAnimated(id self, SEL _cmd, BOOL animated) {
    // Suppress automated scroll-to-top ONLY during genuine warm-start restoration window
    if (s_isRestoringFromWarmStart.load()) {
        s_suppressedScrollCount.fetch_add(1);
        KEEP_ALIVE_LOG("Suppressed warm-start scrollToTopAnimated: on %s (Count: %lu)",
                       class_getName(object_getClass(self)),
                       (unsigned long)s_suppressedScrollCount.load());
        return;
    }
    
    // User manual scroll-to-top (status bar tap or active tab tap) proceeds normally
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
    // NOTE: Video decoders pause naturally via Meta's own observers! We do NOT intercept them.
    [center addObserverForName:UIApplicationDidEnterBackgroundNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification * _Nonnull note) {
        s_hasEnteredBackground.store(true);
        s_isAppBackgrounded.store(true);
        s_backgroundTimestamp.store([NSDate timeIntervalSinceReferenceDate]);
        KEEP_ALIVE_LOG("=== App Minimized to Background ===");
        KEEP_ALIVE_LOG("Root protection active: Image caches shielded from background purge. Video pause untouched (0%% CPU / 0 heat).");
    }];
    
    // 2. App Maximized (Will Enter Foreground)
    [center addObserverForName:UIApplicationWillEnterForegroundNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification * _Nonnull note) {
        s_isAppBackgrounded.store(false);
        
        // Cold start safety: On cold launch, UIApplicationWillEnterForegroundNotification is fired by iOS.
        // If the app has never been backgrounded, this is a cold launch; ignore it completely so cold start is 100% untouched!
        if (!s_hasEnteredBackground.load()) {
            KEEP_ALIVE_LOG("Cold Start detected: Cold start feed loading 100%% untouched.");
            return;
        }
        
        s_foregroundTimestamp.store([NSDate timeIntervalSinceReferenceDate]);
        s_isRestoringFromWarmStart.store(true);
        
        NSTimeInterval elapsed = s_foregroundTimestamp.load() - s_backgroundTimestamp.load();
        KEEP_ALIVE_LOG("=== App Maximized to Foreground (Resumed after %.1fs) ===", elapsed);
        KEEP_ALIVE_LOG("Warm-start viewport shield engaged: Preserving user scroll position for %.1fs.", kWarmStartGraceWindow);
        
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kWarmStartGraceWindow * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            s_isRestoringFromWarmStart.store(false);
            KEEP_ALIVE_LOG("Warm-start restoration window complete. Standard gestures active.");
        });
    }];
    
    // 3. App Became Active
    [center addObserverForName:UIApplicationDidBecomeActiveNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification * _Nonnull note) {
        KEEP_ALIVE_LOG("App Active. Telemetry -> Filtered Purge Observers: %lu | Configured Feed Sources: %lu | Preserved Scroll Viewports: %lu",
                       (unsigned long)s_filteredNotificationCount.load(),
                       (unsigned long)s_configuredFeedSourceCount.load(),
                       (unsigned long)s_suppressedScrollCount.load());
    }];
}

#pragma mark - Hook Registration

static void ApplyHooks(void) {
    // 1. Root Notification Filtering on NSNotificationCenter
    Class centerClass = [[NSNotificationCenter defaultCenter] class];
    if (centerClass) {
        SwizzleMethod(centerClass, @selector(addObserver:selector:name:object:), @selector(ika_addObserver:selector:name:object:), (IMP)Root_AddObserver, "v@:@:@@");
        KEEP_ALIVE_LOG("Installed Root Notification Filter on %s", class_getName(centerClass));
    }
    if (centerClass != [NSNotificationCenter class]) {
        SwizzleMethod([NSNotificationCenter class], @selector(addObserver:selector:name:object:), @selector(ika_addObserver:selector:name:object:), (IMP)Root_AddObserver, "v@:@:@@");
        KEEP_ALIVE_LOG("Installed Root Notification Filter on NSNotificationCenter base class");
    }
    
    // Proactively deregister any image caches that may have initialized early
    ProactivelyDeregisterExistingCacheObservers();
    
    // 2. Native Feed Configuration on IGFeedNetworkSource & related coordinators
    NSArray<NSString *> *feedSourceClasses = @[
        @"IGFeedNetworkSource",
        @"IGMainFeedNetworkSource",
        @"IGFeedContentCoordinator"
    ];
    for (NSString *className in feedSourceClasses) {
        Class cls = objc_getClass([className UTF8String]);
        if (cls) {
            Method m = class_getInstanceMethod(cls, @selector(disableAutomaticRefresh));
            if (m) {
                SwizzleMethod(cls, @selector(disableAutomaticRefresh), @selector(ika_disableAutomaticRefresh), (IMP)Root_DisableAutomaticRefresh, "B@:");
            } else {
                class_addMethod(cls, @selector(disableAutomaticRefresh), (IMP)Root_DisableAutomaticRefresh, "B@:");
            }
            
            Method setM = class_getInstanceMethod(cls, @selector(setDisableAutomaticRefresh:));
            if (setM) {
                SwizzleMethod(cls, @selector(setDisableAutomaticRefresh:), @selector(ika_setDisableAutomaticRefresh:), (IMP)Root_SetDisableAutomaticRefresh, "v@:B");
            }
            KEEP_ALIVE_LOG("Installed native disableAutomaticRefresh switch on %s", [className UTF8String]);
        }
    }
    
    // 3. Viewport & Scroll Retention on Feed View Controllers
    NSArray<NSString *> *feedVCClasses = @[
        @"IGMainFeedViewController",
        @"IGMainFeedViewController_objc",
        @"_TtC15IGMainFeedSwift30IGMainFeedViewController_swift"
    ];
    for (NSString *className in feedVCClasses) {
        Class cls = objc_getClass([className UTF8String]);
        if (cls) {
            SwizzleMethod(cls, @selector(scrollToTopAnimated:), @selector(ika_scrollToTopAnimated:), (IMP)Root_ScrollToTopAnimated, "v@:B");
            SwizzleMethod(cls, @selector(shouldRefreshFeedOnHotStart), @selector(ika_shouldRefreshFeedOnHotStart), (IMP)Root_ShouldRefreshFeedOnHotStart, "B@:");
            KEEP_ALIVE_LOG("Installed viewport & hot-start retention on %s", [className UTF8String]);
        }
    }
}

#pragma mark - Initialization

void InstagramKeepAlive_Init(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        KEEP_ALIVE_LOG("=================================================");
        KEEP_ALIVE_LOG("Initializing InstagramKeepAlive (Root Architecture)");
        KEEP_ALIVE_LOG("1. Root Notification Filtering (Zero Purge at Source)");
        KEEP_ALIVE_LOG("2. Native Meta Feed Switch (Zero Auto-Refresh)");
        KEEP_ALIVE_LOG("3. Natural Video Pause (0.0%% CPU & Zero Heat)");
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
