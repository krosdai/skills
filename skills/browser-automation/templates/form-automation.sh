#!/usr/bin/env bash
# Template: Form Automation Workflow
# Purpose: Fill and submit web forms with validation.
# Usage: ./form-automation.sh <form-url>

set -euo pipefail

: "${READY_SELECTOR:?Set READY_SELECTOR to the page element that confirms this task is ready}"

FORM_URL="${1:?Usage: $0 <form-url>}"

echo "Form automation: $FORM_URL"

agent-browser open "$FORM_URL"
agent-browser wait "$READY_SELECTOR"

echo
echo "Form structure:"
agent-browser snapshot -i

# Update refs after reading the snapshot output.
# Common patterns:
# agent-browser fill @e1 "Jane Doe"
# agent-browser fill @e2 "jane@example.com"
# agent-browser select @e3 "California"
# agent-browser check @e4
# agent-browser upload @e5 ./document.pdf
# agent-browser click @e6

# Wait for submission or redirect when needed.
# agent-browser wait "#expected-result"  # customize for this page
# agent-browser wait --url "**/success"

echo
echo "Result:"
agent-browser get url
agent-browser snapshot -i

agent-browser screenshot /tmp/form-result.png
echo "Screenshot saved: /tmp/form-result.png"

agent-browser close
echo "Done"
