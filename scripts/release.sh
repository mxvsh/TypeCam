#!/usr/bin/env bash
#
# Build a signed App Store IPA for the iOS app.
#
#   scripts/release.sh                 # asks: patch, minor, major or keep
#   scripts/release.sh minor           # no prompt
#   scripts/release.sh patch --upload  # upload to App Store Connect instead of exporting an IPA
#
# Steps: bump the version and build number in the version xcconfig, archive in Release with
# the current git commit embedded, export an IPA (upload it with Transporter) and, if you agree,
# commit the bump and tag it.
#
# Works with any Xcode project whose target takes MARKETING_VERSION and CURRENT_PROJECT_VERSION
# from an xcconfig. Defaults are for TypeCam; override any of them with environment variables:
#
#   PROJECT        path to the .xcodeproj               (ios/TypeCam.xcodeproj)
#   SCHEME         shared scheme to archive             (TypeCam)
#   CONFIGURATION  build configuration                  (Release)
#   VERSION_FILE   xcconfig holding the version         (ios/Config/Version.xcconfig)
#   OUTPUT_DIR     where archives and IPAs go           (build/release)
#   TAG_PREFIX     git tag prefix                       (ios/v)
#   COMMIT_SETTING build setting that receives the git commit (APP_GIT_COMMIT)
#   DEVELOPMENT_TEAM  team ID; overrides the xcconfig (handy on CI)
#
# Signing is automatic: Xcode creates the distribution certificate and App Store profile when
# needed. It authenticates with one of:
#
#   - the Apple account signed in under Xcode › Settings › Accounts (Admin or Account Holder
#     role on the team, so it may create a distribution certificate), or
#   - an App Store Connect API key (App Store Connect › Users and Access › Integrations), with
#     ASC_KEY_PATH (the .p8 file), ASC_KEY_ID and ASC_ISSUER_ID set. No Xcode login needed.
#
# Written for the bash 3.2 that ships with macOS.

set -euo pipefail

# ---- config ---------------------------------------------------------------------------------

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PROJECT="${PROJECT:-ios/TypeCam.xcodeproj}"
SCHEME="${SCHEME:-TypeCam}"
CONFIGURATION="${CONFIGURATION:-Release}"
VERSION_FILE="${VERSION_FILE:-ios/Config/Version.xcconfig}"
OUTPUT_DIR="${OUTPUT_DIR:-build/release}"
TAG_PREFIX="${TAG_PREFIX:-ios/v}"
COMMIT_SETTING="${COMMIT_SETTING:-APP_GIT_COMMIT}"

# ---- helpers --------------------------------------------------------------------------------

if [ -t 1 ]; then
	BOLD=$'\033[1m' DIM=$'\033[2m' RED=$'\033[31m' GREEN=$'\033[32m' YELLOW=$'\033[33m' RESET=$'\033[0m'
else
	BOLD="" DIM="" RED="" GREEN="" YELLOW="" RESET=""
fi

step() { printf '\n%s==>%s %s%s%s\n' "$GREEN" "$RESET" "$BOLD" "$*" "$RESET"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '%swarning:%s %s\n' "$YELLOW" "$RESET" "$*" >&2; }
die() { printf '%serror:%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }

usage() { sed -n '3,8p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

confirm() { # confirm "question" default(y|n)
	local answer hint="[y/N]"
	[ "${2:-n}" = "y" ] && hint="[Y/n]"
	read -r -p "$1 $hint " answer || true
	answer="$(printf '%s' "${answer:-$2}" | tr '[:upper:]' '[:lower:]')"
	[ "$answer" = "y" ] || [ "$answer" = "yes" ]
}

read_setting() { # read_setting KEY FILE -> value of "KEY = value"
	sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\([^[:space:]]*\).*/\1/p" "$2" | head -n 1
}

write_version_file() { # write_version_file VERSION BUILD
	local tmp
	tmp="$(mktemp)"
	sed -e "s/^\([[:space:]]*MARKETING_VERSION[[:space:]]*=[[:space:]]*\).*/\1$1/" \
		-e "s/^\([[:space:]]*CURRENT_PROJECT_VERSION[[:space:]]*=[[:space:]]*\).*/\1$2/" \
		"$VERSION_FILE" >"$tmp"
	cat "$tmp" >"$VERSION_FILE"
	rm -f "$tmp"
}

# ---- arguments ------------------------------------------------------------------------------

BUMP=""
UPLOAD=0
ALLOW_DIRTY=0
for arg in "$@"; do
	case "$arg" in
	major | minor | patch | keep) BUMP="$arg" ;;
	--upload) UPLOAD=1 ;;
	--allow-dirty) ALLOW_DIRTY=1 ;;
	-h | --help) usage 0 ;;
	*) printf 'Unknown argument: %s\n\n' "$arg" >&2; usage 1 ;;
	esac
done

# ---- preflight ------------------------------------------------------------------------------

[ "$(uname -s)" = "Darwin" ] || die "this script needs macOS and Xcode"
command -v xcodebuild >/dev/null || die "xcodebuild not found; install Xcode and run: sudo xcode-select -s /Applications/Xcode.app"
[ -d "$PROJECT" ] || die "project not found: $PROJECT (set PROJECT=…)"
[ -f "$VERSION_FILE" ] || die "version file not found: $VERSION_FILE (set VERSION_FILE=…)"

IN_GIT=0
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
	IN_GIT=1
	if [ "$ALLOW_DIRTY" -eq 0 ] && [ -n "$(git status --porcelain)" ]; then
		die "you have uncommitted changes. Commit or stash them first, or pass --allow-dirty."
	fi
fi

# The commit being built. The version-bump commit made at the end only touches the version file.
GIT_COMMIT="unknown"
if [ "$IN_GIT" -eq 1 ]; then
	GIT_COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
	[ -n "$(git status --porcelain)" ] && GIT_COMMIT="$GIT_COMMIT-dirty"
fi

CURRENT_VERSION="$(read_setting MARKETING_VERSION "$VERSION_FILE")"
CURRENT_BUILD="$(read_setting CURRENT_PROJECT_VERSION "$VERSION_FILE")"

# Accept 1, 1.2 or 1.2.3 and normalise to MAJOR.MINOR.PATCH.
printf '%s' "$CURRENT_VERSION" | grep -Eq '^[0-9]+(\.[0-9]+){0,2}$' ||
	die "MARKETING_VERSION in $VERSION_FILE isn't a version number: '$CURRENT_VERSION'"
printf '%s' "$CURRENT_BUILD" | grep -Eq '^[0-9]+$' ||
	die "CURRENT_PROJECT_VERSION in $VERSION_FILE must be a whole number, got '$CURRENT_BUILD'"

IFS=. read -r MAJOR MINOR PATCH <<<"$CURRENT_VERSION"
MAJOR="${MAJOR:-0}" MINOR="${MINOR:-0}" PATCH="${PATCH:-0}"

version_for() {
	case "$1" in
	major) echo "$((MAJOR + 1)).0.0" ;;
	minor) echo "$MAJOR.$((MINOR + 1)).0" ;;
	patch) echo "$MAJOR.$MINOR.$((PATCH + 1))" ;;
	keep) echo "$MAJOR.$MINOR.$PATCH" ;;
	esac
}

# ---- choose the bump ------------------------------------------------------------------------

NEW_BUILD=$((CURRENT_BUILD + 1))

printf '%s%s%s  ·  current version %s%s%s (build %s)\n' \
	"$BOLD" "$SCHEME" "$RESET" "$BOLD" "$CURRENT_VERSION" "$RESET" "$CURRENT_BUILD"

if [ -z "$BUMP" ]; then
	[ -t 0 ] || die "no bump given and no terminal to ask on. Pass major, minor, patch or keep."
	echo
	echo "What kind of release is this?"
	printf '  1) patch  %s  %sbug fixes%s\n' "$(version_for patch)" "$DIM" "$RESET"
	printf '  2) minor  %s  %snew features%s\n' "$(version_for minor)" "$DIM" "$RESET"
	printf '  3) major  %s  %sbig or breaking changes%s\n' "$(version_for major)" "$DIM" "$RESET"
	printf '  4) keep   %s  %ssame version, new build (e.g. a re-upload after rejection)%s\n' \
		"$(version_for keep)" "$DIM" "$RESET"
	while [ -z "$BUMP" ]; do
		read -r -p "Choose [1-4]: " choice || exit 1
		case "$choice" in
		1 | patch) BUMP=patch ;;
		2 | minor) BUMP=minor ;;
		3 | major) BUMP=major ;;
		4 | keep) BUMP=keep ;;
		*) echo "Please enter 1, 2, 3 or 4." ;;
		esac
	done
fi

NEW_VERSION="$(version_for "$BUMP")"
TAG="$TAG_PREFIX$NEW_VERSION"
# A re-release of an already tagged version gets the build number appended.
if [ "$BUMP" = "keep" ] && [ "$IN_GIT" -eq 1 ] && git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
	TAG="$TAG-$NEW_BUILD"
fi

if [ "$IN_GIT" -eq 1 ] && git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
	die "tag $TAG already exists. Pick a different bump."
fi

echo
info "Version  $CURRENT_VERSION → ${BOLD}$NEW_VERSION${RESET}"
info "Build    $CURRENT_BUILD → ${BOLD}$NEW_BUILD${RESET}"
info "Commit   $GIT_COMMIT"
if [ "$UPLOAD" -eq 1 ]; then info "Output   upload to App Store Connect"; else info "Output   IPA in $OUTPUT_DIR/"; fi
echo
confirm "Continue?" y || exit 0

# Restore the version file if anything below fails, so a broken build doesn't leave a bump behind.
ORIGINAL_VERSION_FILE="$(mktemp)"
cp "$VERSION_FILE" "$ORIGINAL_VERSION_FILE"
DONE=0
cleanup() {
	if [ "$DONE" -eq 0 ]; then
		cat "$ORIGINAL_VERSION_FILE" >"$VERSION_FILE"
		warn "release didn't finish; $VERSION_FILE was restored"
	fi
	rm -f "$ORIGINAL_VERSION_FILE"
}
trap cleanup EXIT

write_version_file "$NEW_VERSION" "$NEW_BUILD"

# ---- signing --------------------------------------------------------------------------------

# Optional App Store Connect API key for provisioning, instead of the Xcode account.
AUTH_ARGS=()
if [ -n "${ASC_KEY_PATH:-}${ASC_KEY_ID:-}${ASC_ISSUER_ID:-}" ]; then
	[ -n "${ASC_KEY_PATH:-}" ] && [ -n "${ASC_KEY_ID:-}" ] && [ -n "${ASC_ISSUER_ID:-}" ] ||
		die "set all three of ASC_KEY_PATH, ASC_KEY_ID and ASC_ISSUER_ID to use an API key"
	[ -f "$ASC_KEY_PATH" ] || die "API key not found: $ASC_KEY_PATH"
	AUTH_ARGS=(-authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID"
		-authenticationKeyIssuerID "$ASC_ISSUER_ID")
fi

EXTRA_SETTINGS=("$COMMIT_SETTING=$GIT_COMMIT")
if [ -n "${DEVELOPMENT_TEAM:-}" ]; then
	TEAM_ID="$DEVELOPMENT_TEAM"
	EXTRA_SETTINGS+=("DEVELOPMENT_TEAM=$TEAM_ID")
else
	step "Reading build settings"
	TEAM_ID="$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIGURATION" \
		-showBuildSettings 2>/dev/null | sed -n 's/^[[:space:]]*DEVELOPMENT_TEAM = //p' | head -n 1)"
fi
[ -n "$TEAM_ID" ] || die "no development team set. Copy ios/Config/Local.xcconfig.example to
       ios/Config/Local.xcconfig and set DEVELOPMENT_TEAM, or run with DEVELOPMENT_TEAM=ABCDE12345."
info "Team $TEAM_ID"

# ---- archive --------------------------------------------------------------------------------

NAME="$SCHEME-$NEW_VERSION-$NEW_BUILD"
ARCHIVE="$OUTPUT_DIR/$NAME.xcarchive"
EXPORT_DIR="$OUTPUT_DIR/$NAME"
LOG_DIR="$OUTPUT_DIR/logs"
mkdir -p "$OUTPUT_DIR" "$LOG_DIR"
rm -rf "$ARCHIVE" "$EXPORT_DIR"

run_logged() { # run_logged LOGFILE cmd… ; quiet unless it fails
	local log="$1"
	shift
	if ! "$@" >"$log" 2>&1; then
		echo
		grep -E 'error:|BUILD FAILED|ARCHIVE FAILED|EXPORT FAILED|\*\* ' "$log" | tail -n 25 >&2 || true
		if grep -q "No Accounts" "$log"; then
			printf '\n%shint:%s %s\n' "$YELLOW" "$RESET" "Xcode isn't signed in to an Apple account. Add one in Xcode › Settings › Accounts" >&2
			printf '      (it needs the Admin or Account Holder role on team %s), or use an App Store Connect\n' "${TEAM_ID:-}" >&2
			printf '      API key with ASC_KEY_PATH, ASC_KEY_ID and ASC_ISSUER_ID. See the top of this script.\n' >&2
		fi
		die "failed. Full log: $log"
	fi
}

step "Archiving $SCHEME $NEW_VERSION ($NEW_BUILD) at $GIT_COMMIT"
info "${DIM}this takes a few minutes · log: $LOG_DIR/archive.log${RESET}"
run_logged "$LOG_DIR/archive.log" xcodebuild archive \
	-project "$PROJECT" \
	-scheme "$SCHEME" \
	-configuration "$CONFIGURATION" \
	-destination "generic/platform=iOS" \
	-archivePath "$ARCHIVE" \
	-allowProvisioningUpdates \
	${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"} \
	${EXTRA_SETTINGS[@]+"${EXTRA_SETTINGS[@]}"}

# ---- export ---------------------------------------------------------------------------------

DESTINATION=export
[ "$UPLOAD" -eq 1 ] && DESTINATION=upload

EXPORT_OPTIONS="$OUTPUT_DIR/ExportOptions.plist"
cat >"$EXPORT_OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>app-store-connect</string>
	<key>destination</key>
	<string>$DESTINATION</string>
	<key>teamID</key>
	<string>$TEAM_ID</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>uploadSymbols</key>
	<true/>
	<key>manageAppVersionAndBuildNumber</key>
	<false/>
</dict>
</plist>
PLIST

if [ "$UPLOAD" -eq 1 ]; then
	step "Uploading to App Store Connect"
else
	step "Exporting IPA"
fi
run_logged "$LOG_DIR/export.log" xcodebuild -exportArchive \
	-archivePath "$ARCHIVE" \
	-exportPath "$EXPORT_DIR" \
	-exportOptionsPlist "$EXPORT_OPTIONS" \
	-allowProvisioningUpdates \
	${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"}

DONE=1

# ---- commit & tag ---------------------------------------------------------------------------

if [ "$IN_GIT" -eq 1 ]; then
	echo
	if confirm "Commit the version bump and tag it $TAG?" y; then
		if git add "$VERSION_FILE" &&
			git commit -q -m "Release $SCHEME $NEW_VERSION ($NEW_BUILD)" &&
			git tag -a "$TAG" -m "$SCHEME $NEW_VERSION ($NEW_BUILD), built from $GIT_COMMIT"; then
			info "Committed and tagged $TAG. Push with: git push --follow-tags"
		else
			warn "couldn't commit or tag. The build is fine; commit $VERSION_FILE yourself."
		fi
	else
		warn "$VERSION_FILE is bumped but not committed. Commit it, or the next release will reuse this build number."
	fi
fi

# ---- done -----------------------------------------------------------------------------------

echo
if [ "$UPLOAD" -eq 1 ]; then
	printf '%sUploaded%s %s %s (%s). It appears in App Store Connect › TestFlight after processing.\n' \
		"$GREEN" "$RESET" "$SCHEME" "$NEW_VERSION" "$NEW_BUILD"
else
	IPA="$(find "$EXPORT_DIR" -maxdepth 1 -name '*.ipa' | head -n 1)"
	[ -n "$IPA" ] || die "export finished but no .ipa was found in $EXPORT_DIR"
	printf '%sReady%s  %s\n' "$GREEN" "$RESET" "$IPA"
	info "Drag it into Transporter and click Deliver."
	[ -t 1 ] && open -R "$IPA" 2>/dev/null || true
fi
