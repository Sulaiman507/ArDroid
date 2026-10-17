#!/bin/sh
# ArDroid system migrations (runs versioned upgrade scripts once).
# Ported from Podroid's OpenRC podroid-migrate: runs early, before the rest
# of the bringup, so migrations can prepare state other services rely on.
set -eu

SYSVER_FILE="/etc/podroid/system-version"
APPLIED_FILE="/mnt/persist/.podroid/applied-version"
MIGRATIONS_DIR="/etc/podroid/migrations"

echo "Running ArDroid migrations..." > /dev/console
mkdir -p /mnt/persist/.podroid

current=$(cat "$SYSVER_FILE" 2>/dev/null || echo 0)
applied=$(cat "$APPLIED_FILE" 2>/dev/null || echo "")

# Fresh install (no marker): seed the marker, run nothing — the squashfs
# already ships the current state.
if [ -z "$applied" ]; then
    printf '%s\n' "$current" > "$APPLIED_FILE.tmp" && mv "$APPLIED_FILE.tmp" "$APPLIED_FILE"
    exit 0
fi

# Fast path / downgrade: nothing to do.
if [ "$current" -le "$applied" ] 2>/dev/null; then
    exit 0
fi

# Run each migrations/<v>.sh with applied < v <= current, in ascending
# numeric order. Scripts MUST be idempotent (a crash mid-run re-runs them
# next boot). Stop at the first failure so it and later scripts re-run.
last_ok="$applied"
failed=0
for base in $(ls "$MIGRATIONS_DIR" 2>/dev/null | sed -n 's/\.sh$//p' | sort -n); do
    case "$base" in *[!0-9]*) continue ;; esac   # digits only
    if [ "$base" -gt "$applied" ] 2>/dev/null && [ "$base" -le "$current" ] 2>/dev/null; then
        echo "podroid-migrate: applying $base" > /dev/console
        if sh "$MIGRATIONS_DIR/$base.sh" > /dev/console 2>&1; then
            last_ok="$base"
        else
            echo "podroid-migrate: $base failed, stopping (will retry next boot)" > /dev/console
            failed=1
            break
        fi
    fi
done

if [ "$failed" -eq 0 ]; then
    marker="$current"
else
    marker="$last_ok"
fi
printf '%s\n' "$marker" > "$APPLIED_FILE.tmp" && mv "$APPLIED_FILE.tmp" "$APPLIED_FILE"
exit 0
