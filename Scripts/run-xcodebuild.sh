#!/usr/bin/env bash

set -u -o pipefail

label="${XCBUILD_LABEL:-xcodebuild}"
raw_log="$(mktemp -t "apelin-${label//\//_}.raw.XXXXXX.log")"
log="$(mktemp -t "apelin-${label//\//_}.XXXXXX.log")"
trap 'rm -f "$raw_log" "$log"' EXIT

if xcodebuild "$@" >"$raw_log" 2>&1; then
    xcode_status=0
else
    xcode_status=$?
fi

perl -pe 's/\r/\n/g; s/\x08//g; s/\x04//g' "$raw_log" >"$log"

if command -v xcbeautify >/dev/null 2>&1; then
    xcbeautify --disable-colored-output --disable-logging <"$log"
else
    cat "$log"
fi

error_pattern='(^|[[:space:]])error:|^\*\* (BUILD|TEST|ARCHIVE|CLEAN|ANALYZE) FAILED \*\*|^Testing failed:|^Failing tests:'
error_lines="$(grep -En "$error_pattern" "$log" 2>/dev/null || true)"

if [[ "$xcode_status" -ne 0 ]]; then
    echo "error: [$label] xcodebuild failed (exit status $xcode_status)" >&2
elif [[ -n "$error_lines" ]]; then
    echo "error: [$label] xcodebuild reported errors (below)" >&2
else
    exit 0
fi
if [[ -n "$error_lines" ]]; then
    head -40 <<<"$error_lines" >&2
else
    # No line matched: the failure is one xcodebuild reported in a shape this
    # grep does not know, and the reason went to the log instead. SwiftPM's
    # `Could not resolve package dependencies:` is that shape — its cause is
    # the lines after it, which are not prefixed with `error:`. Keep them.
    echo "no line matched the error pattern; the log's end follows" >&2
    tail -n 80 "$log" >&2
fi
[[ "$xcode_status" -eq 0 ]] || exit "$xcode_status"
exit 1
