#!/bin/bash

# Build and Export Script for NAKL
# This script builds the app with proper signing and entitlements

echo "Building NAKL for distribution..."

# Clean previous builds
echo "Cleaning previous builds..."
xcodebuild clean -project NAKL.xcodeproj -configuration Release

# Build the app
echo "Building app..."
xcodebuild build -project NAKL.xcodeproj -configuration Release -arch x86_64

# Check if build was successful
if [ $? -eq 0 ]; then
    echo "Build successful!"
    
    # Find the built app
    APP_PATH="build/Release/NAKL.app"
    if [ ! -d "$APP_PATH" ]; then
        APP_PATH="$(find . -name "NAKL.app" -type d | head -1)"
    fi
    
    if [ -d "$APP_PATH" ]; then
        echo "App found at: $APP_PATH"
        
        # Check if app is properly signed
        echo "Checking code signature..."
        codesign --verify --verbose "$APP_PATH"
        
        # Display entitlements
        echo "Checking entitlements..."
        codesign -d --entitlements - "$APP_PATH"
        
        # Check accessibility permissions info
        echo "Checking Info.plist for accessibility description..."
        plutil -p "$APP_PATH/Contents/Info.plist" | grep -A1 NSAccessibilityUsageDescription
        
        echo "Build completed successfully!"
        echo "You can now run the app from: $APP_PATH"
        echo ""
        echo "IMPORTANT NOTES:"
        echo "1. Make sure to grant accessibility permissions when prompted"
        echo "2. If the app doesn't work, check Console.app for NAKL logs"
        echo "3. You may need to sign the app with your developer certificate for distribution"
        
    else
        echo "Error: Could not find built app"
        exit 1
    fi
else
    echo "Build failed!"
    exit 1
fi
