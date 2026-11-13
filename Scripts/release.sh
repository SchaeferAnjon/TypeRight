#!/bin/bash
# Release script for TypeRight (based on TextWarden's)
# Handles: archive, sign, DMG creation, appcast update, GitHub release
#
# Not notarized (2026-11-13, like GetNewWord and Ask Free): without the "TypeRight" notarytool
# keychain profile the release goes out signed with Developer ID only. The first launch then stops
# at Gatekeeper; README, the website and the release notes tell users to click 仍要打开 in
# System Settings › Privacy & Security. Create the profile (see notarize_app) to notarize again.
# One maintainer, no pull requests: the release commit goes on the current branch, unsigned.

set -e
set -o pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Project settings
# The Xcode project, scheme and module keep TextWarden's names; the built app is TypeRight.app.
APP_NAME="TypeRight"
BUNDLE_ID="com.typeright.app"
PROJECT="TextWarden.xcodeproj"
SCHEME="TextWarden"
GITHUB_REPO="SchaeferAnjon/TypeRight"

# Code signing settings
DEVELOPER_ID="Developer ID Application: zonghan jia (3H5S5NXPXS)"
ENTITLEMENTS="TextWarden.entitlements"
APPLE_ID="${APPLE_ID:-}"  # Set via environment or keychain
TEAM_ID="3H5S5NXPXS"
NOTARY_PROFILE="TypeRight"  # xcrun notarytool store-credentials "TypeRight" ...
# Said in the release notes while releases are not notarized.
UNNOTARIZED_NOTE="这一版没有经过苹果公证：第一次打开时如果提示无法验证开发者，打开「系统设置 › 隐私与安全性」，拉到最下面点「仍要打开」。之后自动更新不再弹。"

# Sparkle update signing. The private key lives in the login keychain under its own account,
# like GetNewWord's ("getnewword"), so it never mixes with the other apps' keys.
SPARKLE_ACCOUNT="typeright"
# The keychain asks in a dialog before sign_update may read that key, and the release waits on it.
# SPARKLE_KEY_FROM_ENV=1 pipes the backup in dispatch env to sign_update instead, like Ask Free;
# the key goes through stdin only, never into a file, an argument or the terminal.
SPARKLE_KEY_ENV="TYPERIGHT_SPARKLE_PRIVATE_KEY"
# TextWarden's Sparkle public key, still in Info.plist after the fork. Installed copies accept only
# updates signed by the matching private key, which only TextWarden's author holds.
TEXTWARDEN_SPARKLE_PUBLIC_KEY="Vif5a8JO+wPQUakHgRhQh5ogO7CEZ/cFCAZGHe8ykg0="

# Directories
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
RELEASE_DIR="$PROJECT_ROOT/releases"
# Xcode names the DerivedData folder after the project file (TextWarden.xcodeproj).
SPARKLE_BIN="$HOME/Library/Developer/Xcode/DerivedData/TextWarden-*/SourcePackages/artifacts/sparkle/Sparkle/bin"

# Validate environment and dependencies
validate_environment() {
    echo -e "${BLUE}Validating environment...${NC}" >&2
    local errors=0

    # Check required commands
    local required_cmds=("xcodebuild" "codesign" "hdiutil" "git" "gh" "python3" "cargo" "rustc")
    for cmd in "${required_cmds[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            echo -e "${RED}Error: Required command '$cmd' not found${NC}" >&2
            errors=$((errors + 1))
        fi
    done

    # Check Xcode command line tools
    if ! xcode-select -p &>/dev/null; then
        echo -e "${RED}Error: Xcode command line tools not installed${NC}" >&2
        echo -e "  Run: xcode-select --install" >&2
        errors=$((errors + 1))
    fi

    # Check code signing identity
    if ! security find-identity -v -p codesigning 2>/dev/null | grep -q "$TEAM_ID"; then
        echo -e "${RED}Error: Developer ID certificate not found in keychain${NC}" >&2
        echo -e "  Team ID: $TEAM_ID" >&2
        errors=$((errors + 1))
    fi

    # Check project files exist
    if [[ ! -f "$PROJECT_ROOT/$PROJECT/project.pbxproj" ]]; then
        echo -e "${RED}Error: Xcode project not found at $PROJECT_ROOT/$PROJECT${NC}" >&2
        errors=$((errors + 1))
    fi

    if [[ ! -f "$PROJECT_ROOT/$ENTITLEMENTS" ]]; then
        echo -e "${RED}Error: Entitlements file not found at $PROJECT_ROOT/$ENTITLEMENTS${NC}" >&2
        errors=$((errors + 1))
    fi

    if [[ ! -f "$PROJECT_ROOT/Info.plist" ]]; then
        echo -e "${RED}Error: Info.plist not found${NC}" >&2
        errors=$((errors + 1))
    fi

    # Check git status (warn if dirty)
    if [[ -n "$(git -C "$PROJECT_ROOT" status --porcelain 2>/dev/null)" ]]; then
        echo -e "${YELLOW}Warning: Git working directory has uncommitted changes${NC}" >&2
    fi

    # Check gh CLI is authenticated
    if ! gh auth status &>/dev/null; then
        echo -e "${YELLOW}Warning: GitHub CLI not authenticated (gh release upload will fail)${NC}" >&2
    fi

    if [[ $errors -gt 0 ]]; then
        echo -e "${RED}Environment validation failed with $errors error(s)${NC}" >&2
        exit 1
    fi

    echo -e "${GREEN}Environment validated${NC}" >&2
}

# Find Sparkle tools
find_sparkle_tools() {
    local bin_path=$(ls -d $SPARKLE_BIN 2>/dev/null | head -1)
    if [[ -z "$bin_path" ]]; then
        echo -e "${RED}Error: Sparkle tools not found. Run 'make build' first.${NC}" >&2
        exit 1
    fi
    echo "$bin_path"
}

# Stop before anything is built while Info.plist still carries TextWarden's Sparkle key.
check_sparkle_public_key() {
    local key
    key=$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$PROJECT_ROOT/Info.plist" 2>/dev/null || true)
    local tools
    tools=$(ls -d $SPARKLE_BIN 2>/dev/null | head -1 || true)
    tools="${tools:-<先编译一次，Sparkle 的工具在 DerivedData/TextWarden-*/SourcePackages/artifacts/sparkle/Sparkle/bin>}"
    if [[ -z "$key" ]]; then
        echo -e "${RED}没发：Info.plist 里没有 SUPublicEDKey。${NC}" >&2
        exit 1
    fi
    if [[ "$key" == "$TEXTWARDEN_SPARKLE_PUBLIC_KEY" ]]; then
        echo -e "${RED}没发：Info.plist 的 SUPublicEDKey 还是 TextWarden 的公钥。${NC}" >&2
        echo "装着的 TypeRight 只接受这把公钥对应的私钥签过名的更新，那把私钥在 TextWarden 的作者手里，" >&2
        echo "用它发出去的每一版都会被拒绝。先换成 TypeRight 自己的一对密钥：" >&2
        echo "  1. 生成（只做一次，私钥存进登录钥匙串）：\"$tools/generate_keys\" --account $SPARKLE_ACCOUNT" >&2
        echo "  2. 把它打印的公钥填进 Info.plist 的 SUPublicEDKey，提交" >&2
        echo "  3. 备份私钥：\"$tools/generate_keys\" --account $SPARKLE_ACCOUNT -x <文件>，存到钥匙串以外的安全地方" >&2
        echo "     丢了私钥，装着的 TypeRight 就再也收不到自动更新" >&2
        exit 1
    fi
}

# The private key in the login keychain must be the other half of SUPublicEDKey, or installed
# copies reject the update. generate_keys -p only looks the key up; it never creates one.
check_sparkle_key_pair() {
    local sparkle_bin="$1"
    local expected actual
    if [[ "${SPARKLE_KEY_FROM_ENV:-}" == "1" ]]; then
        # Sign a scrap file before the long build, so a missing or wrong key stops the release here.
        local probe signature
        probe=$(mktemp)
        echo "TypeRight Sparkle key check" > "$probe"
        if ! signature=$(run_sign_update "$sparkle_bin" -p "$probe") || ! signature_matches_info_plist "$probe" "$signature"; then
            rm -f "$probe"
            echo -e "${RED}没发：取不到 dispatch env 的 $SPARKLE_KEY_ENV，或它和 Info.plist 的 SUPublicEDKey 不是一对。${NC}" >&2
            exit 1
        fi
        rm -f "$probe"
        return 0
    fi
    expected=$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$PROJECT_ROOT/Info.plist")
    if ! actual=$("$sparkle_bin/generate_keys" --account "$SPARKLE_ACCOUNT" -p 2>&1); then
        echo -e "${RED}没发：登录钥匙串里没有 account \"$SPARKLE_ACCOUNT\" 的 Sparkle 私钥。${NC}" >&2
        echo "$actual" >&2
        echo "  从备份导入：\"$sparkle_bin/generate_keys\" --account $SPARKLE_ACCOUNT -f <私钥文件>" >&2
        exit 1
    fi
    if [[ "$actual" != "$expected" ]]; then
        echo -e "${RED}没发：钥匙串里的私钥和 Info.plist 的 SUPublicEDKey 不是一对。${NC}" >&2
        echo "  钥匙串里的公钥：$actual" >&2
        echo "  Info.plist 里的：$expected" >&2
        exit 1
    fi
}

# Get version from Info.plist
get_version() {
    /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PROJECT_ROOT/Info.plist"
}

# Get build number from Info.plist
get_build() {
    /usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PROJECT_ROOT/Info.plist"
}

# Set version in Info.plist
set_version() {
    local version="$1"
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$PROJECT_ROOT/Info.plist"
}

# Set build number in Info.plist
set_build() {
    local build="$1"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build" "$PROJECT_ROOT/Info.plist"
}

# Validate semantic versioning format
# Valid: 1.0.0, 0.2.0-alpha.1, 1.0.0-beta.2, 2.0.0-rc.1
# Invalid: v1.0.0, 1.0, 1.0.0-alpha, 1.0.0.0
validate_semver() {
    local version="$1"
    local semver_regex="^[0-9]+\.[0-9]+\.[0-9]+(-((alpha|beta|rc)\.[0-9]+))?$"

    if [[ ! "$version" =~ $semver_regex ]]; then
        echo -e "${RED}Error: Invalid semantic version: $version${NC}"
        echo ""
        echo "Valid formats:"
        echo "  Production:  X.Y.Z        (e.g., 1.0.0, 0.2.0)"
        echo "  Alpha:       X.Y.Z-alpha.N (e.g., 0.2.0-alpha.1)"
        echo "  Beta:        X.Y.Z-beta.N  (e.g., 0.2.0-beta.1)"
        echo "  RC:          X.Y.Z-rc.N    (e.g., 0.2.0-rc.1)"
        echo ""
        echo "Invalid:"
        echo "  - Leading 'v' (use 1.0.0, not v1.0.0)"
        echo "  - Missing patch (use 1.0.0, not 1.0)"
        echo "  - Pre-release without number (use -alpha.1, not -alpha)"
        exit 1
    fi
}

# Parse version type (alpha, beta, rc, release)
parse_version_type() {
    local version="$1"
    if [[ "$version" == *"-alpha."* ]]; then
        echo "alpha"
    elif [[ "$version" == *"-beta."* ]]; then
        echo "beta"
    elif [[ "$version" == *"-rc."* ]]; then
        echo "rc"
    else
        echo "release"
    fi
}

# The last release tag before this version (v*: other tags, like a marker at the fork, do not count)
last_release_tag() {
    local version="$1"
    git -C "$PROJECT_ROOT" tag --list 'v*' --sort=-creatordate | grep -v "^v$version$" | head -1 || true
}

# Release notes. Since the last release: one line per commit (subject and short hash). The first
# release has no tag to start from, and TypeRight's history begins with TextWarden's 1,000 commits,
# so it gets a fixed text instead.
# Note: Does NOT include "Full Changelog" link - that's added only for GitHub releases
generate_release_notes() {
    local from_tag="$1"
    local to_ref="${2:-HEAD}"

    if [[ -z "$from_tag" ]] || ! git -C "$PROJECT_ROOT" rev-parse -q --verify "$from_tag" >/dev/null; then
        cat <<'NOTES'
## TypeRight 第一版

- Mac 菜单栏上的英文打字助手：拼错一个词、不会说先打了中文、一句打完语法不对，它在那个词旁边弹一张小卡，按 Tab 改好，按 Esc 不改
- 拼写和几类常见语法错（像 I has、a apple）在你的 Mac 上用 Harper 查，不联网
- 中文和拼音变英文、整句检查：填自己的 AI Key（DeepSeek、智谱、通义千问等），或开会员（每月 ¥9.9 / $1.99，每天 500 次）
- 按 Tab 改过的记进错题本，从中文变来的词记进生词本，同一个点用对 3 次算会了
- 基于 TextWarden（Apache-2.0）改写，改了哪些见 NOTICE
NOTES
        return
    fi

    echo "## What's Changed"
    echo ""
    git -C "$PROJECT_ROOT" log "$from_tag..$to_ref" --no-merges --pretty=format:"%s|%h" | \
        grep -v "^WIP" | \
        while IFS='|' read -r subject hash; do
            echo "- $subject ([\`$hash\`](https://github.com/$GITHUB_REPO/commit/$hash))"
        done
}

# Generate full changelog link for GitHub releases
# Note: Needs TWO blank lines before for proper markdown separation from list
generate_changelog_link() {
    local from_tag="$1"
    local to_ref="${2:-HEAD}"
    [[ -n "$from_tag" ]] || return 0
    echo ""
    echo ""
    echo "**Full Changelog**: https://github.com/$GITHUB_REPO/compare/$from_tag...$to_ref"
}

# Build release archive
build_archive() {
    echo -e "${BLUE}Building release archive...${NC}" >&2

    # Clean build first
    echo -e "${BLUE}Cleaning previous build...${NC}" >&2
    xcodebuild clean -project "$PROJECT_ROOT/$PROJECT" -scheme "$SCHEME" -configuration Release >/dev/null 2>&1 || true

    # Build Rust in release mode (in subshell to isolate environment)
    echo -e "${BLUE}Building Rust grammar engine...${NC}" >&2
    (
        cd "$PROJECT_ROOT"
        # Ensure clean Rust environment
        export CARGO_TARGET_DIR="$PROJECT_ROOT/GrammarEngine/target"
        export MACOSX_DEPLOYMENT_TARGET="14.0"
        CONFIGURATION=Release ./Scripts/build-rust.sh
    ) >&2

    # Archive (signing handled by Xcode's automatic signing, re-signed during export)
    local archive_path="$RELEASE_DIR/$APP_NAME.xcarchive"
    echo -e "${BLUE}Creating Xcode archive...${NC}" >&2

    # Never allow a failed archive command to fall back to a previous release.
    rm -rf "$archive_path"

    # Run xcodebuild in subshell with clean environment
    if ! (
        cd "$PROJECT_ROOT"
        xcodebuild archive \
            -project "$PROJECT" \
            -scheme "$SCHEME" \
            -configuration Release \
            -destination 'generic/platform=macOS' \
            -archivePath "$archive_path" \
            2>&1 | grep -E "(error:|warning:|ARCHIVE SUCCEEDED|ARCHIVE FAILED)"
    ) >&2; then
        echo -e "${RED}Archive command failed${NC}" >&2
        exit 1
    fi

    # Verify archive succeeded
    if [[ ! -d "$archive_path" ]]; then
        echo -e "${RED}Archive failed - check Xcode build settings${NC}" >&2
        exit 1
    fi

    # Verify the app exists in the archive
    if [[ ! -d "$archive_path/Products/Applications/$APP_NAME.app" ]]; then
        echo -e "${RED}Archive created but app bundle not found${NC}" >&2
        exit 1
    fi

    # Confirm the archive is the release requested in this run.
    local archived_info="$archive_path/Products/Applications/$APP_NAME.app/Contents/Info.plist"
    local archived_version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$archived_info")
    local archived_build=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$archived_info")
    if [[ "$archived_version" != "$(get_version)" || "$archived_build" != "$(get_build)" ]]; then
        echo -e "${RED}Archive version does not match Info.plist${NC}" >&2
        exit 1
    fi

    echo -e "${GREEN}Archive created${NC}" >&2
    echo "$archive_path"
}

# Export app from archive
export_app() {
    local archive_path="$1"
    local export_path="$RELEASE_DIR/export"

    echo -e "${BLUE}Exporting app...${NC}" >&2

    rm -rf "$export_path"
    mkdir -p "$export_path"

    # Copy from archive
    cp -R "$archive_path/Products/Applications/$APP_NAME.app" "$export_path/"

    # Re-sign with Developer ID and entitlements for distribution
    echo -e "${BLUE}Signing app with Developer ID...${NC}" >&2
    # Nested code (Sparkle's helpers and XPC services) keeps its own entitlements; --deep with
    # the app's entitlement file would apply the app's permissions to every helper.
    codesign --force --deep --timestamp --options=runtime \
        --sign "$DEVELOPER_ID" --preserve-metadata=entitlements \
        "$export_path/$APP_NAME.app" || return 1
    # Use release entitlements explicitly to strip Xcode's development-only grants.
    codesign --force --timestamp --options=runtime \
        --sign "$DEVELOPER_ID" \
        --entitlements "$PROJECT_ROOT/$ENTITLEMENTS" \
        "$export_path/$APP_NAME.app" || return 1

    # Verify signature
    if ! codesign --verify --deep --strict "$export_path/$APP_NAME.app" 2>/dev/null; then
        echo -e "${RED}Code signing verification failed${NC}" >&2
        exit 1
    fi

    echo -e "${GREEN}App exported and signed${NC}" >&2
    echo "$export_path/$APP_NAME.app"
}

# Whether this Mac can notarize: the notarytool keychain profile, or APPLE_ID with its password in the keychain
can_notarize() {
    [[ -n "$APPLE_ID" ]] && return 0
    xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1
}

# Notarize the DMG when this Mac can; a failed notarization stops the release. Without credentials
# the release goes out unnotarized (TypeRight's first releases are, like the sibling apps').
notarize_app() {
    local dmg_path="$1"

    if ! can_notarize; then
        echo -e "${YELLOW}不公证：没有 notarytool 的钥匙串配置 \"$NOTARY_PROFILE\"。发布说明里写了第一次打开怎么点「仍要打开」。${NC}"
        echo -e "  以后要公证：xcrun notarytool store-credentials \"$NOTARY_PROFILE\" --apple-id <Apple ID> --team-id $TEAM_ID"
        return 0
    fi
    local auth_args
    if [[ -n "$APPLE_ID" ]]; then
        auth_args="--apple-id $APPLE_ID --team-id $TEAM_ID --password @keychain:AC_PASSWORD"
    else
        auth_args="--keychain-profile $NOTARY_PROFILE"
    fi

    echo -e "${BLUE}Submitting to Apple notary service...${NC}"
    local result
    # Judged below, not by set -e, so the notary's own words are shown.
    result=$(xcrun notarytool submit "$dmg_path" $auth_args --wait 2>&1) || true
    if ! echo "$result" | grep -q "status: Accepted"; then
        echo -e "${RED}Notarization failed:${NC}"
        echo "$result"
        return 1
    fi
    echo -e "${GREEN}Notarization successful${NC}"
    echo -e "${BLUE}Stapling notarization ticket...${NC}"
    xcrun stapler staple "$dmg_path"
    echo -e "${GREEN}Stapling complete${NC}"
}

# Create DMG
create_dmg() {
    local app_path="$1"
    local version="$2"
    local dmg_path="$RELEASE_DIR/$APP_NAME-$version-Universal.dmg"

    echo -e "${BLUE}Creating DMG...${NC}" >&2

    # Remove old DMG if exists
    rm -f "$dmg_path"

    # Create temporary DMG folder
    local dmg_temp="$RELEASE_DIR/dmg_temp"
    rm -rf "$dmg_temp"
    mkdir -p "$dmg_temp"

    # Copy app
    cp -R "$app_path" "$dmg_temp/"

    # Create symlink to Applications
    ln -s /Applications "$dmg_temp/Applications"

    # Create DMG
    hdiutil create -volname "$APP_NAME" \
        -srcfolder "$dmg_temp" \
        -ov -format UDZO \
        "$dmg_path" >/dev/null

    # Cleanup
    rm -rf "$dmg_temp"

    echo -e "${GREEN}DMG created: $dmg_path${NC}" >&2
    echo "$dmg_path"
}

# sign_update with the private key from the keychain, or from dispatch env (SPARKLE_KEY_FROM_ENV=1)
run_sign_update() {
    local sparkle_bin="$1"
    shift
    if [[ "${SPARKLE_KEY_FROM_ENV:-}" == "1" ]]; then
        dispatch env get "$SPARKLE_KEY_ENV" | "$sparkle_bin/sign_update" --ed-key-file - "$@"
    else
        "$sparkle_bin/sign_update" --account "$SPARKLE_ACCOUNT" "$@"
    fi
}

# Whether the signature verifies with Info.plist's SUPublicEDKey, the only key installed copies accept
signature_matches_info_plist() {
    local file="$1"
    local signature="$2"
    local public_key
    public_key=$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$PROJECT_ROOT/Info.plist")
    swift - "$public_key" "$signature" "$file" <<'SWIFT'
import CryptoKit
import Foundation
let a = CommandLine.arguments
guard let pub = Data(base64Encoded: a[1]), let sig = Data(base64Encoded: a[2]),
      let key = try? Curve25519.Signing.PublicKey(rawRepresentation: pub),
      let file = FileManager.default.contents(atPath: a[3]) else { exit(2) }
exit(key.isValidSignature(sig, for: file) ? 0 : 1)
SWIFT
}

# Sign update with Sparkle
sign_update() {
    local dmg_path="$1"
    local sparkle_bin="$2"

    echo -e "${BLUE}Signing update with Sparkle...${NC}" >&2

    # Don't suppress stderr - we need to see errors if keychain access fails
    local raw_signature
    local sign_exit_code=0
    raw_signature=$(run_sign_update "$sparkle_bin" "$dmg_path" 2>&1) || sign_exit_code=$?

    if [[ $sign_exit_code -ne 0 ]]; then
        echo -e "${RED}Failed to sign update (exit code $sign_exit_code):${NC}" >&2
        echo "$raw_signature" >&2
        echo "" >&2
        echo -e "${YELLOW}If keychain access failed, try:${NC}" >&2
        echo -e "  1. Run: security unlock-keychain ~/Library/Keychains/login.keychain-db" >&2
        echo -e "  2. Or: $sparkle_bin/generate_keys --account $SPARKLE_ACCOUNT -p  (to check key access)" >&2
        exit 1
    fi

    if [[ -z "$raw_signature" ]]; then
        echo -e "${RED}Failed to sign update - empty output${NC}" >&2
        exit 1
    fi

    # Extract just the base64 signature from Sparkle's output
    # Format: sparkle:edSignature="<base64>" length="<size>"
    local signature
    if [[ "$raw_signature" =~ edSignature=\"([^\"]+)\" ]]; then
        signature="${BASH_REMATCH[1]}"
    else
        echo -e "${RED}Failed to parse signature from output:${NC}" >&2
        echo "$raw_signature" >&2
        exit 1
    fi

    # CRITICAL: the signature must verify with the public key in Info.plist, or installed copies
    # reject the update. This also catches a key from the wrong keychain item or env entry.
    echo -e "${BLUE}Verifying signature against Info.plist's SUPublicEDKey...${NC}" >&2
    if ! signature_matches_info_plist "$dmg_path" "$signature"; then
        echo -e "${RED}SIGNATURE VERIFICATION FAILED!${NC}" >&2
        echo -e "The signature does not verify with SUPublicEDKey in Info.plist." >&2
        echo -e "The private key used is not the other half of that public key." >&2
        echo "" >&2
        echo -e "Check: $sparkle_bin/generate_keys --account $SPARKLE_ACCOUNT -p (must print SUPublicEDKey)" >&2
        exit 1
    fi

    echo -e "${GREEN}Update signed and verified ✓${NC}" >&2
    echo "$signature"
}

# Convert markdown release notes to HTML for Sparkle
# Handles: ## headers, - lists, **bold**, `code`, [links](url)
convert_markdown_to_html() {
    local markdown="$1"

    python3 << PYEOF
import re
import html

md = '''$markdown'''

# Split into lines for processing
lines = md.strip().split('\n')
html_lines = []
in_list = False

for line in lines:
    # Skip empty lines
    if not line.strip():
        if in_list:
            html_lines.append('</ul>')
            in_list = False
        continue

    # Headers
    if line.startswith('## '):
        if in_list:
            html_lines.append('</ul>')
            in_list = False
        text = html.escape(line[3:])
        html_lines.append(f'<h3>{text}</h3>')
        continue

    # List items
    if line.startswith('- '):
        if not in_list:
            html_lines.append('<ul>')
            in_list = True
        text = line[2:]
        # Convert markdown links [text](url) to HTML
        text = re.sub(r'\[([^\]]+)\]\(([^)]+)\)', r'<a href="\2">\1</a>', text)
        # Convert inline code
        text = re.sub(r'\`([^\`]+)\`', r'<code>\1</code>', text)
        # Convert bold
        text = re.sub(r'\*\*([^*]+)\*\*', r'<b>\1</b>', text)
        # Escape remaining HTML but preserve our tags
        # (links and code already converted, so we just escape plain text parts)
        html_lines.append(f'<li>{text}</li>')
        continue

    # Regular text (like Full Changelog line)
    if in_list:
        html_lines.append('</ul>')
        in_list = False
    text = line
    # Convert markdown links
    text = re.sub(r'\[([^\]]+)\]\(([^)]+)\)', r'<a href="\2">\1</a>', text)
    text = re.sub(r'\*\*([^*]+)\*\*', r'<b>\1</b>', text)
    html_lines.append(f'<p>{text}</p>')

if in_list:
    html_lines.append('</ul>')

print('\n'.join(html_lines))
PYEOF
}

# Update appcast.xml
update_appcast() {
    local version="$1"
    local build="$2"
    local dmg_path="$3"
    local signature="$4"
    local release_notes="$5"
    local is_prerelease="$6"
    local version_type="$7"

    echo -e "${BLUE}Updating appcast.xml...${NC}"

    local dmg_size=$(stat -f%z "$dmg_path")
    local dmg_filename=$(basename "$dmg_path")
    local pub_date=$(date -R)
    local download_url="https://github.com/$GITHUB_REPO/releases/download/v$version/$dmg_filename"
    local appcast="$PROJECT_ROOT/appcast.xml"

    # Add channel element for pre-release versions
    local channel_element=""
    if [[ "$version_type" == "alpha" || "$version_type" == "beta" || "$version_type" == "rc" ]]; then
        channel_element="experimental"
        echo -e "${YELLOW}Adding to experimental channel${NC}"
    fi

    # Convert release notes markdown to HTML for Sparkle
    local html_notes=$(convert_markdown_to_html "$release_notes")

    # Use Python for reliable XML manipulation
    python3 << EOF
import xml.etree.ElementTree as ET
from datetime import datetime
import html

# Parse appcast
tree = ET.parse("$appcast")
root = tree.getroot()

# Define Sparkle namespace
ns = {'sparkle': 'http://www.andymatuschak.org/xml-namespaces/sparkle'}
ET.register_namespace('sparkle', 'http://www.andymatuschak.org/xml-namespaces/sparkle')
ET.register_namespace('', 'http://www.w3.org/2005/Atom')

# Find channel
channel = root.find('channel')
if channel is None:
    print("Error: No channel found in appcast")
    exit(1)

# Find insert position (after title, before first item)
insert_idx = 0
for i, child in enumerate(channel):
    if child.tag == 'title':
        insert_idx = i + 1
        break

# Create new item
item = ET.Element('item')

title = ET.SubElement(item, 'title')
title.text = "$version"

pubDate = ET.SubElement(item, 'pubDate')
pubDate.text = "$pub_date"

sparkle_version = ET.SubElement(item, '{http://www.andymatuschak.org/xml-namespaces/sparkle}version')
sparkle_version.text = "$build"

short_version = ET.SubElement(item, '{http://www.andymatuschak.org/xml-namespaces/sparkle}shortVersionString')
short_version.text = "$version"

min_sys = ET.SubElement(item, '{http://www.andymatuschak.org/xml-namespaces/sparkle}minimumSystemVersion')
min_sys.text = "14.0"

channel_elem_value = "$channel_element"
if channel_elem_value:
    sparkle_channel = ET.SubElement(item, '{http://www.andymatuschak.org/xml-namespaces/sparkle}channel')
    sparkle_channel.text = channel_elem_value

desc = ET.SubElement(item, 'description')
# Embed the HTML release notes
html_notes = '''$html_notes'''
desc.text = html_notes

enclosure = ET.SubElement(item, 'enclosure')
enclosure.set('url', "$download_url")
enclosure.set('length', "$dmg_size")
enclosure.set('type', 'application/octet-stream')
enclosure.set('{http://www.andymatuschak.org/xml-namespaces/sparkle}edSignature', "$signature")

# Insert at position
channel.insert(insert_idx, item)

# Write with proper formatting
tree.write("$appcast", encoding='unicode', xml_declaration=True)

# Pretty print by re-reading and formatting
import xml.dom.minidom
with open("$appcast", 'r') as f:
    content = f.read()
dom = xml.dom.minidom.parseString(content)
pretty = dom.toprettyxml(indent="    ")
# Remove extra blank lines and fix declaration
lines = [l for l in pretty.split('\n') if l.strip()]
lines[0] = '<?xml version="1.0" encoding="UTF-8"?>'
with open("$appcast", 'w') as f:
    f.write('\n'.join(lines))

print("Appcast updated successfully")
EOF

    echo -e "${GREEN}Appcast updated${NC}"
}

# Create GitHub release
create_github_release() {
    local version="$1"
    local dmg_path="$2"
    local appcast_path="$3"
    local release_notes="$4"
    local is_prerelease="$5"

    echo -e "${BLUE}Creating GitHub release...${NC}"

    local prerelease_flag=""
    if [[ "$is_prerelease" == "true" ]]; then
        prerelease_flag="--prerelease"
    fi

    # Create release. Installed copies read releases/latest/download/appcast.xml (SUFeedURL),
    # so the feed is uploaded next to the DMG under exactly that name.
    gh release create "v$version" \
        --title "v$version" \
        --notes "$release_notes" \
        $prerelease_flag \
        "$dmg_path" "$appcast_path"

    echo -e "${GREEN}GitHub release created: v$version${NC}"
}

# Main release function
do_release() {
    local version="$1"
    local skip_confirm="$2"

    if [[ -z "$version" ]]; then
        version=$(get_version)
        echo -e "${YELLOW}No version specified, using current: $version${NC}"
    fi

    # Validate semver before proceeding
    validate_semver "$version"

    # Local checks first: nothing here touches the network or the keychain.
    check_sparkle_public_key

    validate_environment

    local version_type=$(parse_version_type "$version")
    local is_prerelease="false"
    if [[ "$version_type" != "release" ]]; then
        is_prerelease="true"
    fi
    local notarized="no"
    if can_notarize; then notarized="yes"; fi

    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}$APP_NAME Release${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  Version:     ${GREEN}$version${NC}"
    echo -e "  Type:        ${YELLOW}$version_type${NC}"
    echo -e "  Prerelease:  $is_prerelease"
    echo -e "  Notarized:   $notarized"
    echo ""

    # For production releases, require explicit confirmation
    if [[ "$version_type" == "release" && "$skip_confirm" != "--yes" ]]; then
        echo -e "${RED}⚠️  This is a PRODUCTION release!${NC}"
        echo ""
        read -p "Type 'release' to confirm: " confirm
        if [[ "$confirm" != "release" ]]; then
            echo -e "${RED}Aborted${NC}"
            exit 1
        fi
        echo ""
    fi

    # Find Sparkle tools. Declared apart from the assignment so a failure stops the release
    # (local x=$(...) would hide the exit status from set -e).
    local sparkle_bin
    sparkle_bin=$(find_sparkle_tools)
    check_sparkle_key_pair "$sparkle_bin"

    # Create release directory
    mkdir -p "$RELEASE_DIR"

    # Release notes since the last release (nothing is pushed or looked up on GitHub here)
    local last_tag
    last_tag=$(last_release_tag "$version")
    echo -e "${BLUE}Generating release notes...${NC}"
    local release_notes
    release_notes=$(generate_release_notes "$last_tag")
    if [[ "$notarized" == "no" ]]; then
        release_notes+=$'\n\n'"$UNNOTARIZED_NOTE"
    fi
    echo "$release_notes"
    echo ""

    # Update version in Info.plist
    set_version "$version"

    # Increment build number
    local current_build=$(get_build)
    local new_build=$((current_build + 1))
    set_build "$new_build"
    echo -e "Build number: $new_build"

    # Each step below exits on failure inside a command substitution; keep declarations
    # separate so set -e sees that exit status.
    local archive_path
    archive_path=$(build_archive)

    # Export
    local app_path
    app_path=$(export_app "$archive_path")

    # Create DMG
    local dmg_path
    dmg_path=$(create_dmg "$app_path" "$version")

    # Notarize the DMG FIRST (stapling modifies the DMG)
    notarize_app "$dmg_path"

    # Sign with Sparkle AFTER stapling (signature must be for final DMG)
    local signature
    signature=$(sign_update "$dmg_path" "$sparkle_bin")

    # Update appcast
    update_appcast "$version" "$new_build" "$dmg_path" "$signature" "$release_notes" "$is_prerelease" "$version_type"

    # Commit version changes
    echo -e "${BLUE}Committing version changes...${NC}"
    git add "$PROJECT_ROOT/Info.plist" "$PROJECT_ROOT/appcast.xml"
    git commit -m "chore: release v$version"

    # Create git tag
    git tag -a "v$version" -m "Release v$version"

    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}Release prepared: v$version${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "Next steps:"
    echo -e "  1. Review: git log -1 && git diff HEAD~1"
    echo -e "  2. Push:   git push origin HEAD:main && git push origin v$version"
    echo -e "  3. Upload: Scripts/release.sh upload $version"
    echo ""
    echo -e "DMG location: $dmg_path"
}

# Upload release to GitHub
do_upload() {
    local version="$1"

    if [[ -z "$version" ]]; then
        version=$(get_version)
    fi

    local dmg_path="$RELEASE_DIR/$APP_NAME-$version-Universal.dmg"

    if [[ ! -f "$dmg_path" ]]; then
        echo -e "${RED}DMG not found: $dmg_path${NC}"
        echo -e "Run 'make release VERSION=$version' first"
        exit 1
    fi

    # Get the previous tag (excluding the one we're releasing) for release notes
    # This finds the most recent tag that isn't the current version
    local last_tag
    last_tag=$(last_release_tag "$version")
    local release_notes
    release_notes=$(generate_release_notes "$last_tag" "v$version")
    # Add changelog link for GitHub releases (not included in Sparkle appcast)
    release_notes+=$(generate_changelog_link "$last_tag" "v$version")
    # The DMG says whether it was notarized: a stapled ticket.
    if ! xcrun stapler validate "$dmg_path" >/dev/null 2>&1; then
        release_notes+=$'\n\n'"$UNNOTARIZED_NOTE"
    fi

    local version_type=$(parse_version_type "$version")
    local is_prerelease="false"
    if [[ "$version_type" != "release" ]]; then
        is_prerelease="true"
    fi

    # Upload the feed exactly as committed with this release, and only if it lists this DMG.
    local appcast_path="$RELEASE_DIR/appcast.xml"
    git -C "$PROJECT_ROOT" show "v$version:appcast.xml" > "$appcast_path"
    local download_url="https://github.com/$GITHUB_REPO/releases/download/v$version/$(basename "$dmg_path")"
    if ! grep -qF "url=\"$download_url\"" "$appcast_path"; then
        echo -e "${RED}appcast.xml at v$version has no entry for $download_url${NC}"
        exit 1
    fi

    create_github_release "$version" "$dmg_path" "$appcast_path" "$release_notes" "$is_prerelease"

    echo ""
    echo -e "${GREEN}Release uploaded!${NC}"
    echo -e "View at: https://github.com/$GITHUB_REPO/releases/tag/v$version"
    if [[ "$is_prerelease" == "true" ]]; then
        echo -e "${YELLOW}预发布版不会成为 GitHub 的 latest：装着的 TypeRight 读 releases/latest/download/appcast.xml，${NC}"
        echo -e "${YELLOW}拿到的是最近一个正式版的 appcast。还没发过正式版时，这个地址是 404。${NC}"
    fi
}

# Show usage
usage() {
    echo "Usage: $0 <command> [options]"
    echo ""
    echo "Commands:"
    echo "  release [VERSION]     Build and prepare release"
    echo "  upload [VERSION]      Upload prepared release to GitHub"
    echo "  notes [FROM_TAG] [TO_TAG]  Generate release notes (no FROM_TAG: since the last v* tag, or the first-release text)"
    echo "  version               Show current version"
    echo ""
    echo "Examples:"
    echo "  $0 release 0.2.0-alpha.1"
    echo "  $0 release 0.2.0-beta.1"
    echo "  $0 release 0.2.0-rc.1"
    echo "  $0 release 0.2.0"
    echo "  $0 upload 0.2.0"
}

# Main
case "${1:-}" in
    release)
        do_release "$2" "$3"
        ;;
    upload)
        do_upload "$2"
        ;;
    notes)
        generate_release_notes "${2:-$(last_release_tag "")}" "$3"
        ;;
    version)
        echo "$(get_version) (build $(get_build))"
        ;;
    *)
        usage
        ;;
esac
