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

SESSION_OPEN=false
trap 'agent-browser close >/dev/null 2>&1 || true' EXIT
if [[ -f "$STATE_FILE" ]]; then
  echo "Loading saved state from $STATE_FILE..."
  if agent-browser --state "$STATE_FILE" open "$LOGIN_URL" 2>/dev/null; then
    SESSION_OPEN=true
    # A transient login form or URL is not evidence that asynchronous restore failed.
    # Use the browser's bounded element wait for positive authentication evidence.
    if agent-browser wait "$AUTH_READY_SELECTOR"; then
      echo "Session restored successfully"
      agent-browser snapshot -i
      exit 0
    fi
    echo "Authentication not confirmed; preserving saved state for inspection."
  else
    echo "Could not load saved state; preserving the file for inspection."
    agent-browser close 2>/dev/null || true
  fi
fi

if [[ "$SESSION_OPEN" != true ]]; then
  echo "Opening login page for discovery..."
  agent-browser open "$LOGIN_URL"
fi
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

exit 0

# Example login flow to customize for the target site:
# : "${APP_USERNAME:?Set APP_USERNAME}"
# : "${APP_PASSWORD:?Set APP_PASSWORD}"
# agent-browser open "$LOGIN_URL"
# agent-browser wait "$LOGIN_READY_SELECTOR"
# agent-browser snapshot -i
# agent-browser fill @e1 "$APP_USERNAME"
# agent-browser fill @e2 "$APP_PASSWORD"
# agent-browser click @e3
# if ! agent-browser wait "$AUTH_READY_SELECTOR"; then
#   echo "Login failed"
#   agent-browser screenshot /tmp/login-failed.png
#   agent-browser close
#   exit 1
# fi
# agent-browser state save "$STATE_FILE"
# echo "Login successful"
# agent-browser snapshot -i
