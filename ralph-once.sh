#!/bin/bash
#
# ralph-once.sh — Human-in-the-loop Ralph
# Runs one task from the PRD, commits, updates progress.
# Re-run manually to continue through the task list.
#

TMPFILE=$(mktemp)
CHILD_PID=""

cleanup() {
  echo ""
  echo "=========================================="
  echo "  Interrupted."
  echo "  $(date)"
  echo "=========================================="
  [ -n "$CHILD_PID" ] && kill "$CHILD_PID" 2>/dev/null
  rm -f "$TMPFILE"
  exit 130
}
trap cleanup INT TERM

claude --permission-mode acceptEdits "@PRD.md @progress.txt \
1. Read the PRD and progress file carefully. \
2. Find the next incomplete task (unchecked checkbox) and implement it fully. \
3. Write thorough tests and ensure they pass with 'mix test'. \
4. Read the corresponding Python source files in python/RNS/ as your reference — match behavior exactly. \
5. Check the checkbox in PRD.md for the completed task. \
6. Commit your changes with a descriptive message. \
7. Append a summary of what you did to progress.txt with a timestamp. \
ONLY DO ONE TASK AT A TIME. \
If all tasks are complete, say COMPLETE." > "$TMPFILE" 2>&1 &
CHILD_PID=$!
wait "$CHILD_PID"
CHILD_PID=""

cat "$TMPFILE"
rm -f "$TMPFILE"
