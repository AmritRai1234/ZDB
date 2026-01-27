#!/bin/bash
# Build ZMDB for Android platforms

set -e

echo "Building ZMDB for Android..."

# Check for Zig
if ! command -v zig &> /dev/null; then
    echo "Error: Zig compiler not found"
    exit 1
fi

# Build for ARM64 (most modern Android devices)
echo "Building for Android ARM64..."
zig build-lib src/lib.zig \
    -target aarch64-linux-android \
    -O ReleaseFast \
    -femit-bin=zig-out/lib/android/arm64-v8a/libzmdb.so \
    -dynamic

# Build for ARMv7 (older Android devices)
echo "Building for Android ARMv7..."
zig build-lib src/lib.zig \
    -target arm-linux-androideabi \
    -O ReleaseFast \
    -femit-bin=zig-out/lib/android/armeabi-v7a/libzmdb.so \
    -dynamic

# Build for x86_64 (emulator)
echo "Building for Android x86_64..."
zig build-lib src/lib.zig \
    -target x86_64-linux-android \
    -O ReleaseFast \
    -femit-bin=zig-out/lib/android/x86_64/libzmdb.so \
    -dynamic

echo "Android builds complete!"
echo "Libraries available in zig-out/lib/android/"
