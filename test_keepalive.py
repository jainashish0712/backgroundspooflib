#!/usr/bin/env python3
"""
Comprehensive Unit Test Suite for InstagramKeepAlive
Tests Approach 2 (Surgical Warm-Start & Memory Purge Neutralization):
- Warm-start interval and timer spoofing
- Memory purge neutralization during app minimize
- Viewport retention & warm-start auto-scroll suppression
- Lifecycle state transitions and thread concurrency
"""

import unittest
import threading
import time

class MockKeepAliveEngine:
    """
    Python mock simulating the exact C++/Objective-C runtime logic
    implemented in InstagramKeepAlive.mm
    """
    def __init__(self):
        self.kInfiniteInterval = 86400000.0
        self.kInfiniteTimerSeconds = 86400000
        self.kWarmStartGraceWindow = 0.2  # shortened for fast unit tests

        self.is_active = False
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

    def get_suppressed_refresh_count(self):
        with self._lock:
            return self.suppressed_refresh_count

    def get_suppressed_scroll_count(self):
        with self._lock:
            return self.suppressed_scroll_count

    def get_spoofed_timer_count(self):
        with self._lock:
            return self.spoofed_timer_count

    # Lifecycle Events
    def on_app_did_enter_background(self):
        with self._lock:
            self.is_app_backgrounded = True
            self.background_timestamp = time.time()

    def on_app_will_enter_foreground(self):
        with self._lock:
            self.is_app_backgrounded = False
            self.foreground_timestamp = time.time()
            self.is_restoring_from_warm_start = True

    def end_warm_start_grace_window(self):
        with self._lock:
            self.is_restoring_from_warm_start = False

    # Hook Replacements
    def hook_purge_no_op(self, method_name):
        with self._lock:
            self.suppressed_purge_count += 1
        return None

    def hook_clear_memory_cache(self, factor):
        with self._lock:
            if self.is_app_backgrounded:
                self.suppressed_purge_count += 1
                return False  # Suppressed
            return True  # Allowed outside backgrounding

    def hook_should_refresh_feed_on_hot_start(self):
        with self._lock:
            self.spoofed_timer_count += 1
        return False  # Always return NO

    def hook_warm_start_refresh_interval(self):
        with self._lock:
            self.spoofed_timer_count += 1
        return self.kInfiniteInterval

    def hook_warm_start_refresh_timer_in_seconds(self):
        with self._lock:
            self.spoofed_timer_count += 1
        return self.kInfiniteTimerSeconds

    def hook_time_since_background(self):
        with self._lock:
            self.spoofed_timer_count += 1
        return 0.0

    def hook_scroll_to_top_animated(self, animated):
        with self._lock:
            if self.is_restoring_from_warm_start:
                self.suppressed_scroll_count += 1
                return False  # Suppressed
            return True  # Allowed (e.g. user tap status bar)

    def hook_refresh_feed_with_fetch_reason(self, reason, animated):
        with self._lock:
            if self.is_restoring_from_warm_start:
                self.suppressed_refresh_count += 1
                return False  # Suppressed
            return True  # Allowed (manual user pull-to-refresh)


class TestInstagramKeepAlive(unittest.TestCase):

    def setUp(self):
        self.engine = MockKeepAliveEngine()
        self.engine.init()

    def test_engine_initialization(self):
        self.assertTrue(self.engine.is_active)
        self.assertFalse(self.engine.is_app_backgrounded)
        self.assertFalse(self.engine.is_restoring_from_warm_start)

    def test_warm_start_timer_spoofing(self):
        # 1. shouldRefreshFeedOnHotStart MUST return False (NO)
        should_refresh = self.engine.hook_should_refresh_feed_on_hot_start()
        self.assertFalse(should_refresh, "shouldRefreshFeedOnHotStart must return NO")

        # 2. warmStartRefreshInterval MUST return infinite interval (86400000.0s)
        interval = self.engine.hook_warm_start_refresh_interval()
        self.assertEqual(interval, 86400000.0, "warmStartRefreshInterval must return infinite interval")

        # 3. warmStartRefreshTimerInSeconds MUST return infinite seconds
        timer_seconds = self.engine.hook_warm_start_refresh_timer_in_seconds()
        self.assertEqual(timer_seconds, 86400000, "warmStartRefreshTimerInSeconds must return 86400000")

        # 4. _timeSinceBackground MUST return 0.0s
        elapsed = self.engine.hook_time_since_background()
        self.assertEqual(elapsed, 0.0, "_timeSinceBackground must return 0.0s")

        self.assertEqual(self.engine.get_spoofed_timer_count(), 4)

    def test_background_memory_purge_neutralization(self):
        # When app minimizes to background
        self.engine.on_app_did_enter_background()
        self.assertTrue(self.engine.is_app_backgrounded)

        # Stories and Reels purge methods must NO-OP
        self.engine.hook_purge_no_op("ios_purge_26_q2_IGHomeSundialFeedStoriesManager_handleAppDidEnterBackground")
        self.engine.hook_purge_no_op("handleAppDidEnterBackground")
        self.engine.hook_purge_no_op("ios_purge_26_q3_IGMetaAIReelsMidcardSectionController_handleDidEnterBackground")

        # Cache clearing while backgrounded must be blocked
        cache_cleared = self.engine.hook_clear_memory_cache(None)
        self.assertFalse(cache_cleared, "Cache clearing must be suppressed while app is backgrounded")

        self.assertEqual(self.engine.get_suppressed_purge_count(), 4)

    def test_warm_start_auto_scroll_suppression(self):
        # Background then foreground
        self.engine.on_app_did_enter_background()
        self.engine.on_app_will_enter_foreground()

        self.assertFalse(self.engine.is_app_backgrounded)
        self.assertTrue(self.engine.is_restoring_from_warm_start)

        # During warm-start restoration window, scrollToTopAnimated: must be SUPPRESSED
        scrolled = self.engine.hook_scroll_to_top_animated(True)
        self.assertFalse(scrolled, "scrollToTopAnimated: must be suppressed during warm-start restoration")
        self.assertEqual(self.engine.get_suppressed_scroll_count(), 1)

        # Feed reload during restoration must be SUPPRESSED
        reloaded = self.engine.hook_refresh_feed_with_fetch_reason(1, False)
        self.assertFalse(reloaded, "refreshFeedWithFetchReason: must be suppressed during warm-start restoration")
        self.assertEqual(self.engine.get_suppressed_refresh_count(), 1)

        # After grace window expires, user actions must work normally
        self.engine.end_warm_start_grace_window()
        self.assertFalse(self.engine.is_restoring_from_warm_start)

        # Manual scroll-to-top (e.g. user taps status bar) should now SUCCEED
        manual_scroll = self.engine.hook_scroll_to_top_animated(True)
        self.assertTrue(manual_scroll, "Manual scrollToTopAnimated: must succeed outside warm-start grace window")

        # Manual pull-to-refresh should now SUCCEED
        manual_refresh = self.engine.hook_refresh_feed_with_fetch_reason(1, True)
        self.assertTrue(manual_refresh, "Manual pull-to-refresh must succeed outside warm-start grace window")

    def test_multithreaded_concurrency(self):
        # Stress test concurrent hooks from multiple background threads
        def worker():
            for _ in range(100):
                self.engine.hook_should_refresh_feed_on_hot_start()
                self.engine.hook_purge_no_op("testPurge")

        threads = [threading.Thread(target=worker) for _ in range(10)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()

        self.assertEqual(self.engine.get_spoofed_timer_count(), 1000)
        self.assertEqual(self.engine.get_suppressed_purge_count(), 1000)


if __name__ == "__main__":
    unittest.main()
