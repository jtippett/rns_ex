#!/bin/bash
#
# afk-ralph.sh — Autonomous Ralph loop
# Runs N iterations, each completing one PRD task.
# Usage: ./afk-ralph.sh <iterations>
#

TMPFILE=$(mktemp)
CHILD_PID=""
i=0

cleanup() {
  echo ""
  echo "=========================================="
  echo "  Interrupted after $i iterations."
  echo "  $(date)"
  echo "=========================================="
  [ -n "$CHILD_PID" ] && kill "$CHILD_PID" 2>/dev/null
  rm -f "$TMPFILE"
  exit 130
}
trap cleanup INT TERM

if [ -z "$1" ]; then
  echo "Usage: $0 <iterations>"
  echo "Example: $0 20"
  exit 1
fi

ITERATIONS=$1
echo "Starting Ralph loop for up to $ITERATIONS iterations..."
echo "---"

for ((i=1; i<=$ITERATIONS; i++)); do
  echo ""
  echo "=========================================="
  echo "  Ralph iteration $i of $ITERATIONS"
  echo "  $(date)"
  echo "=========================================="
  echo ""

  claude -p --permission-mode acceptEdits \
  "@PRD.md @progress.txt \
  1. Read the PRD and progress file carefully. \
  2. Find the next incomplete task (unchecked checkbox) and implement it fully. If it has been started, continue from where it left off. \
  3. Write thorough tests and ensure they pass with 'mix test'. \
  4. Read the corresponding Python source files in python/RNS/ as your reference — match behavior exactly. \
  5. Check the checkbox in PRD.md for the completed task. \
  6. Commit your changes with a descriptive message. \
  7. Append a summary of what you did to progress.txt with a timestamp. \
  ONLY DO ONE TASK AT A TIME. \
  If all tasks are complete, output COMPLETE and nothing else." > "$TMPFILE" 2>&1 &
  CHILD_PID=$!
  wait "$CHILD_PID"
  wait_status=$?
  CHILD_PID=""

  if [ $wait_status -ne 0 ] && [ $wait_status -ne 0 ]; then
    # If wait was interrupted by signal, cleanup trap will handle it.
    # If claude itself failed, report and continue.
    if [ $wait_status -gt 128 ]; then
      # Killed by signal — trap will fire, but just in case:
      cleanup
    fi
    echo "Warning: claude exited with status $wait_status"
  fi

  result=$(cat "$TMPFILE")
  echo "$result"

  if [[ "$result" == *"COMPLETE"* ]]; then
    echo ""
    echo "=========================================="
    echo "  PRD complete after $i iterations!"
    echo "  $(date)"
    echo "=========================================="
    rm -f "$TMPFILE"
    exit 0
  fi
done

echo ""
echo "=========================================="
echo "  Reached iteration limit ($ITERATIONS)."
echo "  Run again to continue."
echo "  $(date)"
echo "=========================================="
rm -f "$TMPFILE"
