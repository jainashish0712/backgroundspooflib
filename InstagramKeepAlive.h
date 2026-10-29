//
//  InstagramKeepAlive.h
//  InstagramKeepAlive
//
//  Root-Level Keep-Alive & Feed Retention Architecture
//  Eliminates runtime getter wrapping by using:
//  1. Root Notification Filtering (Blocks image cache purge registration at the event root)
//  2. Native Meta Feed Configuration (Enables built-in _disableAutomaticRefresh at creation root)
//  3. Natural Video/Audio Pause Lifecycle (Guarantees 0.0% CPU & zero background heating)
//

#ifndef INSTAGRAM_KEEP_ALIVE_H
#define INSTAGRAM_KEEP_ALIVE_H

#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Initialize the root keep-alive and feed retention engine.
/// Safe to call multiple times (guarded by dispatch_once).
void InstagramKeepAlive_Init(void);

/// Returns YES if InstagramKeepAlive is actively initialized and running.
BOOL InstagramKeepAlive_IsActive(void);

/// Returns YES if Instagram is currently in the background state.
BOOL InstagramKeepAlive_IsBackgrounded(void);

/// Telemetry counters for diagnostics
NSUInteger InstagramKeepAlive_FilteredNotificationCount(void);
NSUInteger InstagramKeepAlive_ConfiguredFeedSourceCount(void);
NSUInteger InstagramKeepAlive_SuppressedScrollCount(void);

#ifdef __cplusplus
}
#endif

#endif /* INSTAGRAM_KEEP_ALIVE_H */
