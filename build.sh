#!/usr/bin/env bash
set -e

echo "Building InstagramKeepAlive.dylib for arm64/arm64e iOS..."

SDK_PATH=$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null || echo "")

FRAMEWORKS="-framework Foundation -framework UIKit"

if [ -n "$SDK_PATH" ]; then
    xcrun -sdk iphoneos clang++ -dynamiclib -arch arm64 -arch arm64e \
        -miphoneos-version-min=14.0 \
        -isysroot "$SDK_PATH" \
        $FRAMEWORKS \
        -O3 -fobjc-arc -std=c++17 \
        InstagramKeepAlive.mm -lc++ \
        -o InstagramKeepAlive.dylib
else
    echo "Using direct clang++..."
    clang++ -dynamiclib -target arm64-apple-ios14.0 \
        $FRAMEWORKS \
        -O3 -fobjc-arc -std=c++17 \
        InstagramKeepAlive.mm -lc++ \
        -o InstagramKeepAlive.dylib
fi

echo "Successfully built InstagramKeepAlive.dylib!"
