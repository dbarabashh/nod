#!/usr/bin/env bash
#
# Checks the two hardcoded bundle-identifier lists against what is actually
# installed on this Mac:
#
#   * `ScreenExclusions.defaultExcludedMessengers` — messengers excluded from
#     ambient capture before the user configures anything.
#   * `ConferencingApp` — the apps meeting detection and the roster reader look
#     at.
#
# Both match by bundle identifier, which fails silently: an app that ships
# under a second identifier (Telegram has three) is simply not covered, and
# nothing anywhere says so. For the messenger list that means private
# conversation in the index — the exact thing the list exists to prevent.
#
# The check: for every installed app whose name carries a word we claim to
# cover, its identifier has to be in the matching list. Names come from the
# lists themselves, so adding an app to Swift extends the check for free.
#
# Run it before a release. Exits non-zero when something is uncovered.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXCLUSIONS="${ROOT}/Nod/Core/Screen/ScreenExclusions.swift"
CONFERENCING="${ROOT}/Nod/Core/Screen/MeetingRoster.swift"

# id<TAB>keyword, one per line.
messenger_entries() {
    grep -oE 'ExcludedApp\(bundleID: "[^"]+", name: "[^"]+"\)' "$EXCLUSIONS" \
        | sed -E 's/ExcludedApp\(bundleID: "([^"]+)", name: "([^"]+)"\)/\1\t\2/' \
        | awk -F'\t' '{ split($2, w, " "); print $1 "\t" tolower(w[1]) }'
}

conferencing_entries() {
    grep -oE '^ +case [a-zA-Z]+ = "[^"]+"' "$CONFERENCING" \
        | sed -E 's/^ +case ([a-zA-Z]+) = "([^"]+)"/\2\t\1/' \
        | awk -F'\t' '{ print $1 "\t" tolower($2) }'
}

# Every installed app as: id<TAB>name. Same search paths as `InstalledApps`.
installed_apps() {
    local dir app id name
    for dir in /Applications /System/Applications /System/Applications/Utilities \
               /Applications/Utilities "${HOME}/Applications"; do
        [ -d "$dir" ] || continue
        for app in "$dir"/*.app; do
            [ -d "$app" ] || continue
            id="$(defaults read "${app}/Contents/Info" CFBundleIdentifier 2>/dev/null || true)"
            [ -n "$id" ] || continue
            name="$(basename "$app" .app)"
            printf '%s\t%s\n' "$id" "$name"
        done
    done
}

# Does an app name contain `keyword` as a whole word? Substring matching would
# call Archive Utility an Arc window.
name_has_keyword() {
    local name="$1" keyword="$2" word
    for word in $(printf '%s' "$name" | tr '[:upper:]' '[:lower:]' | tr -c '[:alnum:]' ' '); do
        [ "$word" = "$keyword" ] && return 0
    done
    return 1
}

check_list() {
    local label="$1" entries="$2" installed="$3" failures=0
    local ids keywords id keyword app_id app_name

    ids="$(printf '%s\n' "$entries" | cut -f1)"
    keywords="$(printf '%s\n' "$entries" | cut -f2 | sort -u)"

    if [ -z "$(printf '%s' "$ids" | tr -d '[:space:]')" ]; then
        echo "error: found no entries for ${label} — the source moved and this check is now blind" >&2
        return 1
    fi

    while IFS=$'\t' read -r app_id app_name; do
        [ -n "$app_id" ] || continue
        for keyword in $keywords; do
            name_has_keyword "$app_name" "$keyword" || continue
            if ! printf '%s\n' "$ids" | grep -qxF "$app_id"; then
                echo "  UNCOVERED  ${app_name} (${app_id}) — matches \"${keyword}\" but is not in ${label}"
                failures=$((failures + 1))
            fi
            break
        done
    done <<< "$installed"

    if [ "$failures" -eq 0 ]; then
        echo "  ok — every installed app matching ${label} is covered"
    fi
    return "$failures"
}

INSTALLED="$(installed_apps)"
STATUS=0

echo "==> messenger exclusions (ScreenExclusions.defaultExcludedMessengers)"
check_list "the messenger list" "$(messenger_entries)" "$INSTALLED" || STATUS=1

echo "==> conferencing apps (ConferencingApp)"
check_list "ConferencingApp" "$(conferencing_entries)" "$INSTALLED" || STATUS=1

if [ "$STATUS" -ne 0 ]; then
    echo
    echo "An uncovered app is not cosmetic: a messenger missing from the list is read"
    echo "by ambient capture, and a conferencing app missing from ConferencingApp is a"
    echo "call Nod never offers to record. Add the identifier and re-run."
fi

exit "$STATUS"
