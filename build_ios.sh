#!/bin/bash
# Build ZMDB for iOS platforms

set -e

echo "Building ZMDB for iOS..."

# Check for Zig
if ! command -v zig &> /dev/null; then
    echo "Error: Zig compiler not found"
    exit 1
fi

# Build for iOS ARM64 (devices)
echo "Building for iOS ARM64..."
zig build-lib src/lib.zig \
    -target aarch64-ios \
    -O ReleaseFast \
    -femit-bin=zig-out/lib/ios/libzmdb.a

# Build for iOS Simulator ARM64 (M1/M2 Macs)
echo "Building for iOS Simulator ARM64..."
zig build-lib src/lib.zig \
    -target aarch64-ios-simulator \
    -O ReleaseFast \
    -femit-bin=zig-out/lib/ios-simulator/libzmdb.a

# Build for iOS Simulator x86_64 (Intel Macs)
echo "Building for iOS Simulator x86_64..."
zig build-lib src/lib.zig \
    -target x86_64-ios-simulator \
    -O ReleaseFast \
    -femit-bin=zig-out/lib/ios-simulator-x86/libzmdb.a

echo "iOS builds complete!"
echo "Libraries available in zig-out/lib/ios*/"
