#!/bin/bash

# Test Reset Script for TypeRight
# Resets the app to fresh state for testing onboarding

set -e

APP_PROCESS="TypeRight"
BUNDLE_ID="com.typeright.app"
SUPPORT_DIR="$HOME/Library/Application Support/$BUNDLE_ID"

echo "🧪 TypeRight Test Reset Script"
echo "========================="
echo ""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 1. Kill running instances
echo -e "${YELLOW}1. Killing any running $APP_PROCESS instances...${NC}"
killall "$APP_PROCESS" 2>/dev/null || echo "  ℹ️  No running instances found"
sleep 1

# 2. Clear preferences
echo -e "${YELLOW}2. Clearing preferences...${NC}"
defaults delete "$BUNDLE_ID" 2>/dev/null && echo "  ✅ Preferences cleared" || echo "  ℹ️  No preferences found"

# 3. Clear application support (TypeRight's own folder; TextWarden's is left alone)
echo -e "${YELLOW}3. Clearing application support folder...${NC}"
if [ -d "$SUPPORT_DIR" ]; then
    rm -rf "$SUPPORT_DIR"
    echo "  ✅ Application support cleared"
else
    echo "  ℹ️  No application support folder found"
fi

# 4. Check accessibility permission status
echo -e "${YELLOW}4. Checking Accessibility permission status...${NC}"
if grep -q "$BUNDLE_ID" "/Library/Application Support/com.apple.TCC/TCC.db" 2>/dev/null; then
    echo -e "  ${RED}⚠️  TypeRight still has Accessibility permission${NC}"
    echo "  📝 To fully reset, manually remove from:"
    echo "     System Settings → Privacy & Security → Accessibility"
    echo ""
    read -p "  Press Enter to open System Settings..."
    open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
else
    echo "  ✅ No Accessibility permission found"
fi

echo ""
echo -e "${GREEN}✅ Reset complete!${NC}"
echo ""
echo "Next steps:"
echo "  1. If needed, remove TypeRight from Accessibility in System Settings"
echo "  2. Launch TypeRight from Xcode or Finder"
echo "  3. Follow TESTING_GUIDE.md for comprehensive testing"
echo ""
