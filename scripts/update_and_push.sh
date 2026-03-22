#!/usr/bin/env bash
# QSL Dashboard — Collect status + git push for Vercel auto-deploy
# Cron: */5 * * * *
set -euo pipefail

DASHBOARD_DIR="$HOME/qsl-dashboard"
LOG="$DASHBOARD_DIR/logs/update.log"
mkdir -p "$DASHBOARD_DIR/logs"

{
  echo "=== $(date -u) ==="

  # Collect status
  bash "$DASHBOARD_DIR/scripts/collect_status.sh"

  # Git add + commit + push (only if changed)
  cd "$DASHBOARD_DIR"
  if git diff --quiet data/status.json 2>/dev/null; then
    echo "No changes to push"
  else
    git add data/status.json
    git commit -m "auto: update status $(date -u +%H:%M)" --no-gpg-sign -q
    git push -q origin main 2>&1
    echo "Pushed to GitHub"
  fi
} >> "$LOG" 2>&1

# Keep log under 1000 lines
tail -1000 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
