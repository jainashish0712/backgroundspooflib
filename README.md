# InstagramKeepAlive

A high-performance, battery-efficient iOS tweak for Instagram that implements **Surgical Warm-Start & Memory Purge Neutralization** (Approach 2).

## What It Does
When Instagram is minimized (swiped up to home or app switcher):
1. **Zero Memory/RAM Purging**: Prevents Instagram from flushing feed data, reels (sundial) video segments, stories, and image caches from RAM.
2. **Zero Warm-Start Feed Reloading**: Spoofs warm-start intervals to infinite thresholds and background elapsed time to `0.0s`, completely neutralizing Instagram's forced feed reload on return.
3. **Exact Scroll Position Retention**: Blocks Instagram's automated `scrollToTopAnimated:` on warm-start restoration while preserving manual user scroll-to-top actions (e.g. tapping the status bar).
4. **0% Battery Waste & 0 Heating**: Unlike virtual keep-alive loops that spin background CPU threads, this tweak allows the iOS kernel to suspend threads naturally when minimized.

---

## Technical Mechanism (Approach 2)

### 1. Memory Purge Neutralization
- **Stories & Reels**: Hooks `-[IGHomeSundialFeedStoriesManager ios_purge_26_q2_IGHomeSundialFeedStoriesManager_handleAppDidEnterBackground]` and `handleAppDidEnterBackground` -> safe NO-OP.
- **Image Caches**: Intercepts `clearMemoryCache:`, `clearInMemoryCache`, and `clearInnerMemoryCache` on `IGUnifiedImageMemoryCache`, `_IGImageServiceMemoryCache`, and `MOSImageMemoryCache` during background transitions.
- **Auxiliary Controllers**: Hooks background purge handlers across `IGMetaAIReelsMidcardSectionController`, `IGShortDramaSeriesPageViewController`, and `IGDirectVoiceRecordViewController`.

### 2. Warm-Start Interval Spoofing
- `-[IGMainFeedViewController shouldRefreshFeedOnHotStart]` -> Returns `NO`.
- `warmStartRefreshInterval`, `warmStartRefreshIntervalOnPeak`, `minimumWarmStartBackgroundedInterval`, `minimumWarmStartBackgroundedIntervalOnPeak` -> Returns `86400000.0s` (~1000 days).
- `_timeSinceBackground` -> Returns `0.0s`.
- `didEnterBackgroundDate`, `lastDidEnterBackgroundDate` -> Returns `[NSDate date]` (difference = 0.0s).

### 3. Auto-Scroll & Viewport Retention
- During the `kWarmStartGraceWindow` (2.0s after returning to foreground):
  - `scrollToTopAnimated:` is suppressed.
  - `refreshFeedWithFetchReason:animated:` is suppressed.
- Outside the restoration window, all normal user gestures and manual refreshes remain fully functional.

---

## Build Instructions

### Using Theos:
```bash
make package
```

### Using standalone `build.sh`:
```bash
./build.sh
```

---

## Testing & Verification

Run the test suite:
```bash
python verify_syntax.py
python test_keepalive.py
```
