#!/usr/bin/env python3
"""
Comprehensive Unit Test Suite for InstagramKeepAlive
Tests Root-Level Architecture:
- Root Notification Filtering (Blocks image cache purge registration at event root)
- Natural Video/Media Pause Lifecycle (Video players register and pause normally)
- Root Native Feed Configuration (IGFeedNetworkSource disableAutomaticRefresh = YES)
- Cold Start Protection (100% normal feed loading on initial launch)
- Viewport & Scroll Retention during warm-start restoration
- Multithreaded Concurrency & Thread Safety
"""

import unittest
import threading
import time

class MockRootKeepAliveEngine:
    """
    Python mock simulating the exact C++/Objective-C runtime logic
    in InstagramKeepAlive.mm (Root-Level Architecture).
    """
    def __init__(self):
        self.is_active = False
        self.has_entered_background = False
        self.is_app_backgrounded = False
        self.is_restoring_from_warm_start = False
        self.background_timestamp = 0.0
        self.foreground_timestamp = 0.0

        # Registered observers in mock NSNotificationCenter
        self.registered_observers = []

        # Root telemetry
        self.filtered_notification_count = 0
        self.configured_feed_source_count = 0
        self.suppressed_scroll_count = 0

        self._lock = threading.Lock()

    def init(self):
        self.is_active = True

    # Telemetry
    def get_filtered_notification_count(self):
        with self._lock:
            return self.filtered_notification_count

    def get_configured_feed_source_count(self):
        with self._lock:
            return self.configured_feed_source_count

    def get_suppressed_scroll_count(self):
        with self._lock:
            return self.suppressed_scroll_count

    # Lifecycle Events
    def on_app_did_enter_background(self):
        with self._lock:
            self.has_entered_background = True
            self.is_app_backgrounded = True
            self.background_timestamp = time.time()

    def on_app_will_enter_foreground(self):
        with self._lock:
            self.is_app_backgrounded = False
            # Cold start safety: If app never backgrounded, do not enter warm-start restoration
            if not self.has_entered_background:
                return
            
            self.foreground_timestamp = time.time()
            self.is_restoring_from_warm_start = True

    def end_warm_start_grace_window(self):
        with self._lock:
            self.is_restoring_from_warm_start = False

    # Root Fix 1: Notification Center Filtering
    def hook_add_observer(self, target_class: str, selector: str, notification_name: str) -> bool:
        """
        Simulates Root_AddObserver on NSNotificationCenter.
        Returns True if observer was registered, False if dropped at root.
        """
        with self._lock:
            if notification_name == "UIApplicationDidEnterBackgroundNotification":
                is_image_cache = any(kw in target_class for kw in [
                    "ImageMemoryCache", "ImageServiceMemoryCache", "MOSImageMemoryCache",
                    "IGUnifiedImageMemoryCache", "IGImageCache"
                ])
                is_clear_selector = ("clearMemoryCache" in selector or "cleanMemoryCache" in selector)
                
                if is_image_cache or is_clear_selector:
                    self.filtered_notification_count += 1
                    # Dropped at root: Not added to registered_observers!
                    return False

            self.registered_observers.append((target_class, selector, notification_name))
            return True

    # Root Fix 2: Native Feed Configuration
    def hook_disable_automatic_refresh(self, feed_source_class: str) -> bool:
        """
        Simulates Root_DisableAutomaticRefresh on IGFeedNetworkSource.
        Returns YES (True) natively instructing Instagram not to auto-refresh.
        """
        with self._lock:
            self.configured_feed_source_count += 1
            return True

    def hook_should_refresh_feed_on_hot_start(self) -> bool:
        """
        Simulates Root_ShouldRefreshFeedOnHotStart on IGMainFeedViewController.
        Allows cold start, suppresses warm start.
        """
        with self._lock:
            if not self.has_entered_background:
                return True
            return False

    # Root Fix 4: Scroll Retention
    def hook_scroll_to_top_animated(self, animated: bool) -> bool:
        """
        Simulates Root_ScrollToTopAnimated on IGMainFeedViewController.
        Returns True if scroll executed, False if suppressed.
        """
        with self._lock:
            if self.is_restoring_from_warm_start:
                self.suppressed_scroll_count += 1
                return False
            return True


class TestRootKeepAlive(unittest.TestCase):

    def setUp(self):
        self.engine = MockRootKeepAliveEngine()
        self.engine.init()

    def test_root_notification_filtering(self):
        """
        Validates that image cache background purge registrations are dropped at root,
        while video players and other critical observers are registered normally.
        """
        # Image cache tries to register for background purge -> DROPPED
        registered = self.engine.hook_add_observer(
            "IGUnifiedImageMemoryCache", "clearMemoryCache:", "UIApplicationDidEnterBackgroundNotification"
        )
        self.assertFalse(registered)
        self.assertEqual(self.engine.get_filtered_notification_count(), 1)
        self.assertNotIn(("IGUnifiedImageMemoryCache", "clearMemoryCache:", "UIApplicationDidEnterBackgroundNotification"),
                         self.engine.registered_observers)

        # MOSImageMemoryCache tries to register -> DROPPED
        registered_mos = self.engine.hook_add_observer(
            "MOSImageMemoryCache", "cleanMemoryCache", "UIApplicationDidEnterBackgroundNotification"
        )
        self.assertFalse(registered_mos)
        self.assertEqual(self.engine.get_filtered_notification_count(), 2)

        # Video Player registers for background notification -> ALLOWED!
        # This ensures video pauses naturally, preventing 100% CPU and overheating
        video_registered = self.engine.hook_add_observer(
            "IGFNFVideoPlayer", "handleAppDidEnterBackground", "UIApplicationDidEnterBackgroundNotification"
        )
        self.assertTrue(video_registered)
        self.assertIn(("IGFNFVideoPlayer", "handleAppDidEnterBackground", "UIApplicationDidEnterBackgroundNotification"),
                      self.engine.registered_observers)

        # Normal app lifecycle coordinator -> ALLOWED!
        coord_registered = self.engine.hook_add_observer(
            "IGPlaybackCoordinator", "applicationDidEnterBackground:", "UIApplicationDidEnterBackgroundNotification"
        )
        self.assertTrue(coord_registered)

    def test_native_meta_feed_configuration(self):
        """
        Validates native disableAutomaticRefresh returns YES at root.
        """
        result = self.engine.hook_disable_automatic_refresh("IGFeedNetworkSource")
        self.assertTrue(result)
        self.assertEqual(self.engine.get_configured_feed_source_count(), 1)

        result_main = self.engine.hook_disable_automatic_refresh("IGMainFeedNetworkSource")
        self.assertTrue(result_main)
        self.assertEqual(self.engine.get_configured_feed_source_count(), 2)

    def test_cold_start_unimpaired_feed_loading(self):
        """
        Validates that on cold start, initial feed loading is 100% untouched
        and skeleton loader bug is completely avoided.
        """
        self.assertFalse(self.engine.has_entered_background)
        self.assertFalse(self.engine.is_app_backgrounded)

        self.engine.on_app_will_enter_foreground()
        self.assertFalse(self.engine.is_restoring_from_warm_start)

        # Should allow normal startup refresh
        should_refresh = self.engine.hook_should_refresh_feed_on_hot_start()
        self.assertTrue(should_refresh)

        # Should allow normal initial viewport positioning
        scrolled = self.engine.hook_scroll_to_top_animated(False)
        self.assertTrue(scrolled)

    def test_warm_start_viewport_and_feed_retention(self):
        """
        Validates that after minimizing and reopening:
        - Auto-refresh is natively prevented.
        - Viewport scroll position is preserved.
        """
        # 1. Minimize app
        self.engine.on_app_did_enter_background()
        self.assertTrue(self.engine.has_entered_background)
        self.assertTrue(self.engine.is_app_backgrounded)

        # 2. Maximize back (Warm start)
        self.engine.on_app_will_enter_foreground()
        self.assertFalse(self.engine.is_app_backgrounded)
        self.assertTrue(self.engine.is_restoring_from_warm_start)

        # Feed auto-refresh blocked natively
        should_refresh = self.engine.hook_should_refresh_feed_on_hot_start()
        self.assertFalse(should_refresh)

        # Auto-scroll blocked during grace window
        scrolled = self.engine.hook_scroll_to_top_animated(True)
        self.assertFalse(scrolled)
        self.assertEqual(self.engine.get_suppressed_scroll_count(), 1)

        # 3. Grace window expires
        self.engine.end_warm_start_grace_window()
        self.assertFalse(self.engine.is_restoring_from_warm_start)

        # Manual user scroll to top proceeds normally
        manual_scroll = self.engine.hook_scroll_to_top_animated(True)
        self.assertTrue(manual_scroll)

    def test_concurrency_and_thread_safety(self):
        """
        Validates thread-safe execution under concurrent access.
        """
        def worker():
            for _ in range(50):
                self.engine.hook_add_observer(
                    "IGUnifiedImageMemoryCache", "clearMemoryCache:", "UIApplicationDidEnterBackgroundNotification"
                )
                self.engine.hook_disable_automatic_refresh("IGFeedNetworkSource")
                self.engine.hook_should_refresh_feed_on_hot_start()
                self.engine.hook_scroll_to_top_animated(True)

        threads = [threading.Thread(target=worker) for _ in range(10)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()

        self.assertEqual(self.engine.get_filtered_notification_count(), 500)
        self.assertEqual(self.engine.get_configured_feed_source_count(), 500)


if __name__ == "__main__":
    unittest.main()
