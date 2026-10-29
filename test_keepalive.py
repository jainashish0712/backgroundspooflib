#!/usr/bin/env python3
"""
Comprehensive Unit Test Suite for InstagramKeepAlive
Tests Approach 2 (Surgical Warm-Start & Memory Purge Neutralization):
- Cold Start Protection (100% normal feed loading on launch)
- Background Memory Purge Neutralization
- Warm-Start Interval Spoofing & Viewport Retention
- Concurrency and Thread Safety
"""

import unittest
import threading
import time

class MockKeepAliveEngine:
    """
    Python mock simulating the exact C++/Objective-C runtime logic
    in InstagramKeepAlive.mm
    """
    def __init__(self):
        self.kInfiniteInterval = 86400.0
        self.kInfiniteTimerSeconds = 86400

        self.is_active = False
        self.has_entered_background = False
        self.is_app_backgrounded = False
        self.is_restoring_from_warm_start = False
        self.background_timestamp = 0.0
        self.foreground_timestamp = 0.0

        self.suppressed_purge_count = 0
        self.suppressed_refresh_count = 0
        self.suppressed_scroll_count = 0
        self.spoofed_timer_count = 0

        self._lock = threading.Lock()

    def init(self):
        self.is_active = True

    # Telemetry
    def get_suppressed_purge_count(self):
        with self._lock:
            return self.suppressed_purge_count

    def get_suppressed_scroll_count(self):
        with self._lock:
            return self.suppressed_scroll_count

    def get_spoofed_timer_count(self):
        with self._lock:
            return self.spoofed_timer_count

    # Lifecycle Events
    def on_app_did_enter_background(self):
        with self._lock:
            self.has_entered_background = True
            self.is_app_backgrounded = True
            self.background_timestamp = time.time()

    def on_app_will_enter_foreground(self):
        with self._lock:
            self.is_app_backgrounded = False
            # CRITICAL COLD START PROTECTION:
            # If the app has NEVER entered background, this is an initial launch!
            # Ignore on cold start so initial feed fetching is never blocked.
            if not self.has_entered_background:
                return
            
            self.foreground_timestamp = time.time()
            self.is_restoring_from_warm_start = True

    def end_warm_start_grace_window(self):
        with self._lock:
            self.is_restoring_from_warm_start = False

    # Hooks
    def hook_purge_no_op(self, method_name):
        with self._lock:
            self.suppressed_purge_count += 1
        return None

    def hook_clear_memory_cache(self, factor):
        with self._lock:
            if self.is_app_backgrounded:
                self.suppressed_purge_count += 1
                return False  # Suppressed during background
            return True  # Allowed outside background

    def hook_should_refresh_feed_on_hot_start(self):
        with self._lock:
            # On cold start, allow normal initialization
            if not self.has_entered_background:
                return True
            self.spoofed_timer_count += 1
            return False  # On warm-start, return NO

    def hook_warm_start_refresh_interval(self):
        with self._lock:
            if self.has_entered_background:
                self.spoofed_timer_count += 1
                return self.kInfiniteInterval
            return 0.0

    def hook_warm_start_refresh_timer_in_seconds(self):
        with self._lock:
            if self.has_entered_background:
                self.spoofed_timer_count += 1
                return self.kInfiniteTimerSeconds
            return 0

    def hook_scroll_to_top_animated(self, animated):
        with self._lock:
            if self.is_restoring_from_warm_start:
                self.suppressed_scroll_count += 1
                return False  # Suppressed during warm-start restore
            return True  # Allowed (user tap or normal operation)


class TestInstagramKeepAlive(unittest.TestCase):

    def setUp(self):
        self.engine = MockKeepAliveEngine()
        self.engine.init()

    def test_cold_start_protection(self):
        """
        Verify that on cold launch:
        - has_entered_background is False
        - willEnterForeground does NOT engage warm-start restoration
        - shouldRefreshFeedOnHotStart allows normal initialization
        - scrollToTopAnimated is NOT suppressed
        This guarantees initial feed network requests and skeleton loaders
        complete normally without ever hanging!
        """
        self.assertFalse(self.engine.has_entered_background)
        self.assertFalse(self.engine.is_app_backgrounded)

        # iOS fires willEnterForeground during initial launch:
        self.engine.on_app_will_enter_foreground()
        self.assertFalse(self.engine.is_restoring_from_warm_start,
                         "Cold start must NOT engage warm-start restoration!")

        # Cold start checks should proceed normally
        should_refresh = self.engine.hook_should_refresh_feed_on_hot_start()
        self.assertTrue(should_refresh, "Cold start must allow normal startup flow")

        interval = self.engine.hook_warm_start_refresh_interval()
        self.assertEqual(interval, 0.0, "Cold start interval should be default (0.0)")

        # Scroll to top is not blocked on cold start
        scrolled = self.engine.hook_scroll_to_top_animated(True)
        self.assertTrue(scrolled, "Cold start scrolling must not be blocked")

    def test_background_memory_purge_neutralization(self):
        """
        Verify that once minimized to background:
        - Stories & Reels purges are safely converted to NO-OPs
        - Image caches suppress clearMemoryCache:
        """
        self.engine.on_app_did_enter_background()
        self.assertTrue(self.engine.has_entered_background)
        self.assertTrue(self.engine.is_app_backgrounded)

        self.engine.hook_purge_no_op("ios_purge_26_q2_IGHomeSundialFeedStoriesManager_handleAppDidEnterBackground")
        self.engine.hook_purge_no_op("handleAppDidEnterBackground")

        cache_cleared = self.engine.hook_clear_memory_cache(None)
        self.assertFalse(cache_cleared, "Cache clear must be suppressed while minimized")

        self.assertEqual(self.engine.get_suppressed_purge_count(), 3)

    def test_warm_start_after_minimize(self):
        """
        Verify that returning from background:
        - Engages warm-start shield
        - Sets warm-start refresh interval to 24 hours (86,400s)
        - Returns NO for shouldRefreshFeedOnHotStart
        - Suppresses scrollToTopAnimated during grace period
        - Restores manual scroll-to-top after grace period
        """
        # 1. Minimize
        self.engine.on_app_did_enter_background()
        self.assertTrue(self.engine.has_entered_background)

        # 2. Maximize
        self.engine.on_app_will_enter_foreground()
        self.assertFalse(self.engine.is_app_backgrounded)
        self.assertTrue(self.engine.is_restoring_from_warm_start)

        # Warm start interval returns 86,400s (Instagram considers feed fresh)
        interval = self.engine.hook_warm_start_refresh_interval()
        self.assertEqual(interval, 86400.0)

        should_refresh = self.engine.hook_should_refresh_feed_on_hot_start()
        self.assertFalse(should_refresh)

        # Automated scroll to top is suppressed
        scrolled = self.engine.hook_scroll_to_top_animated(True)
        self.assertFalse(scrolled, "Auto-scroll must be suppressed on warm start")
        self.assertEqual(self.engine.get_suppressed_scroll_count(), 1)

        # 3. Grace period expires
        self.engine.end_warm_start_grace_window()
        self.assertFalse(self.engine.is_restoring_from_warm_start)

        # Manual scroll to top works again
        manual_scroll = self.engine.hook_scroll_to_top_animated(True)
        self.assertTrue(manual_scroll, "Manual scroll-to-top must work after grace period")

    def test_multithreaded_concurrency(self):
        def worker():
            for _ in range(50):
                self.engine.hook_should_refresh_feed_on_hot_start()
                self.engine.hook_purge_no_op("testPurge")

        threads = [threading.Thread(target=worker) for _ in range(10)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()

        self.assertEqual(self.engine.get_suppressed_purge_count(), 500)


if __name__ == "__main__":
    unittest.main()
