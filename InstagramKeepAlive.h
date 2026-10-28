//
//  InstagramKeepAlive.h
//  InstagramKeepAlive
//
//  Approach 2: Surgical Warm-Start & Memory Purge Neutralization
//  Prevents Instagram from clearing memory/RAM on minimize,
//  and eliminates forced feed/reels auto-refresh & auto-scroll on maximize.
//

#ifndef INSTAGRAM_KEEP_ALIVE_H
#define INSTAGRAM_KEEP_ALIVE_H

#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Initialize the keep-alive, anti-purge, and anti-refresh engine.
/// Safe to call multiple times (guarded by dispatch_once).
void InstagramKeepAlive_Init(void);

/// Returns YES if InstagramKeepAlive is actively initialized and running.
BOOL InstagramKeepAlive_IsActive(void);

/// Returns YES if Instagram is currently in the background state.
BOOL InstagramKeepAlive_IsBackgrounded(void);

/// Returns YES if Instagram is currently in the warm-start restoration window.
BOOL InstagramKeepAlive_IsRestoringFromWarmStart(void);

/// Telemetry counters for diagnostics
NSUInteger InstagramKeepAlive_SuppressedPurgeCount(void);
NSUInteger InstagramKeepAlive_SuppressedRefreshCount(void);
NSUInteger InstagramKeepAlive_SuppressedScrollCount(void);
NSUInteger InstagramKeepAlive_SpoofedTimerCount(void);

#ifdef __cplusplus
}
#endif

#endif /* INSTAGRAM_KEEP_ALIVE_H */
