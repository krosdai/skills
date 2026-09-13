#!/usr/bin/env bash
# Template: Content Capture Workflow
# Purpose: Extract content from a page and save evidence.
# Usage: ./capture-workflow.sh <url> [output-dir]

set -euo pipefail

: "${READY_SELECTOR:?Set READY_SELECTOR to the page element that confirms this task is ready}"

TARGET_URL="${1:?Usage: $0 <url> [output-dir]}"
OUTPUT_DIR="${2:-.}"

echo "Capturing: $TARGET_URL"
mkdir -p "$OUTPUT_DIR"

agent-browser open "$TARGET_URL"
agent-browser wait "$READY_SELECTOR"

TITLE="$(agent-browser get title)"
URL="$(agent-browser get url)"
echo "Title: $TITLE"
echo "URL: $URL"

agent-browser screenshot --full "$OUTPUT_DIR/page-full.png"
echo "Saved: $OUTPUT_DIR/page-full.png"

agent-browser snapshot -i > "$OUTPUT_DIR/page-structure.txt"
echo "Saved: $OUTPUT_DIR/page-structure.txt"

agent-browser get text body > "$OUTPUT_DIR/page-text.txt"
echo "Saved: $OUTPUT_DIR/page-text.txt"

agent-browser pdf "$OUTPUT_DIR/page.pdf"
echo "Saved: $OUTPUT_DIR/page.pdf"

agent-browser close

echo
echo "Capture complete:"
eza -la "$OUTPUT_DIR"
