#!/usr/bin/env bash
# Template: Authenticated Session Discovery Workflow
# Purpose: Reuse saved state when available, otherwise inspect the login flow and prepare a state-saving login script.
# Usage: ./authenticated-session.sh <login-url> [state-file]

set -euo pipefail

: "${LOGIN_READY_SELECTOR:?Set LOGIN_READY_SELECTOR to the settled login form CSS selector}"
: "${AUTH_READY_SELECTOR:?Set AUTH_READY_SELECTOR to authenticated landing content CSS selector}"

LOGIN_URL="${1:?Usage: $0 <login-url> [state-file]}"
STATE_FILE="${2:-./auth-state.json}"
# A reused session may reach either the login form or authenticated content.

echo "Authentication workflow: $LOGIN_URL"
echo "Prefer the agent-browser auth vault when possible."

if [[ -f "$STATE_FILE" ]]; then
  echo "Loading saved state from $STATE_FILE..."
  if agent-browser --state "$STATE_FILE" open "$LOGIN_URL" 2>/dev/null; then
    agent-browser wait "$LOGIN_READY_SELECTOR, $AUTH_READY_SELECTOR"
    CURRENT_URL="$(agent-browser get url)"
    if [[ "$CURRENT_URL" != *"login"* ]] && [[ "$CURRENT_URL" != *"signin"* ]]; then
      echo "Session restored successfully"
      agent-browser snapshot -i
      agent-browser close
      exit 0
    fi
    echo "Session expired, performing fresh login..."
    agent-browser close 2>/dev/null || true
  fi
  rm -f "$STATE_FILE"
fi

echo "Opening login page for discovery..."
agent-browser open "$LOGIN_URL"
agent-browser wait "$LOGIN_READY_SELECTOR"

echo
echo "Login form structure:"
echo "---"
agent-browser snapshot -i
echo "---"
echo
echo "Next steps:"
echo "  1. Note the refs for username, password, and submit."
echo "  2. Use the auth vault if the environment allows it."
echo "  3. If you need saved state, customize the example login flow below."
echo "  4. Re-run the customized commands to save $STATE_FILE."

agent-browser close
exit 0

# Example login flow to customize for the target site:
# : "${APP_USERNAME:?Set APP_USERNAME}"
# : "${APP_PASSWORD:?Set APP_PASSWORD}"
# agent-browser open "$LOGIN_URL"
# agent-browser wait "#expected-result"  # customize for this page
# agent-browser snapshot -i
# agent-browser fill @e1 "$APP_USERNAME"
# agent-browser fill @e2 "$APP_PASSWORD"
# agent-browser click @e3
# agent-browser wait "#expected-result"  # customize for this page
# FINAL_URL="$(agent-browser get url)"
# if [[ "$FINAL_URL" == *"login"* ]] || [[ "$FINAL_URL" == *"signin"* ]]; then
#   echo "Login failed"
#   agent-browser screenshot /tmp/login-failed.png
#   agent-browser close
#   exit 1
# fi
# agent-browser state save "$STATE_FILE"
# echo "Login successful"
# agent-browser snapshot -i
