#!/usr/bin/env bash
# seedance.sh — Generate video via Volcengine Seedance 2.0 API
# Supports: Seedance 2.0 (quality) and 2.0 Fast (speed+cost). Rejects non-2.0 models.
#
# Usage:
#   seedance.sh "prompt text" [options]
#
# Options:
#   --image URL          First-frame image URL
#   --last-image URL     Last-frame image URL (requires --image)
#   --ref-image URL      Reference image (repeatable, up to 9)
#   --ref-video URL      Reference video (repeatable, up to 3, total ≤15s)
#   --ref-audio URL      Reference audio (repeatable, up to 3)
#   --model MODEL        Model ID (default: $SEEDANCE_MODEL or doubao-seedance-2-0-fast-260128)
#   --ratio RATIO        Aspect ratio (default: 16:9)
#   --duration SECS      Duration in seconds, 4-15 or -1 for auto (default: 5)
#   --resolution RES     Resolution: 480p or 720p (default: 720p)
#   --audio true|false   Generate audio (default: true)
#   --watermark          Add watermark
#   --web-search         Enable web search (text-to-video only)
#   --api-key KEY        API key (default: $SEEDANCE_API_KEY)
#   --base-url URL       Base URL (default: $SEEDANCE_BASE_URL or https://ark.cn-beijing.volces.com)
#   --poll-interval SECS Polling interval (default: 10)
#   --max-wait SECS      Network/wait budget in seconds (default: 600)
#   --task-id ID         Resume querying an existing task; never create a new one
#   --download DIR       Download video to directory
#
# Environment:
#   SEEDANCE_API_KEY     API key (required)
#   SEEDANCE_BASE_URL    Base URL override (for proxies/gateways)
#   SEEDANCE_MODEL       Default model override

set -euo pipefail

# --- Dependency check ---
for cmd in curl jq; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "❌ Required command not found: $cmd" >&2
    exit 1
  fi
done

DEFAULT_BASE_URL="https://ark.cn-beijing.volces.com"
BASE_URL="${SEEDANCE_BASE_URL:-$DEFAULT_BASE_URL}"
MODEL="${SEEDANCE_MODEL:-doubao-seedance-2-0-fast-260128}"
RATIO="16:9"
DURATION=5
RESOLUTION="720p"
GENERATE_AUDIO=true
WATERMARK=false
WEB_SEARCH=false
API_KEY="${SEEDANCE_API_KEY:-}"
API_KEY_FROM_FLAG=false
POLL_INTERVAL=10
MAX_WAIT=600
DOWNLOAD_DIR=""
TASK_ID=""

PROMPT=""
FIRST_IMAGE=""
LAST_IMAGE=""
REF_IMAGES=()
REF_VIDEOS=()
REF_AUDIOS=()

# --- Helper: require argument value ---
require_arg() {
  if [[ $# -lt 2 || -z "$2" ]]; then
    echo "❌ Option $1 requires an argument." >&2
    exit 1
  fi
}

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --image)         require_arg "$1" "${2:-}"; FIRST_IMAGE="$2"; shift 2 ;;
    --last-image)    require_arg "$1" "${2:-}"; LAST_IMAGE="$2"; shift 2 ;;
    --ref-image)     require_arg "$1" "${2:-}"; REF_IMAGES+=("$2"); shift 2 ;;
    --ref-video)     require_arg "$1" "${2:-}"; REF_VIDEOS+=("$2"); shift 2 ;;
    --ref-audio)     require_arg "$1" "${2:-}"; REF_AUDIOS+=("$2"); shift 2 ;;
    --model)         require_arg "$1" "${2:-}"; MODEL="$2"; shift 2 ;;
    --ratio)         require_arg "$1" "${2:-}"; RATIO="$2"; shift 2 ;;
    --duration)      require_arg "$1" "${2:-}"; DURATION="$2"; shift 2 ;;
    --resolution)    require_arg "$1" "${2:-}"; RESOLUTION="$2"; shift 2 ;;
    --audio)         require_arg "$1" "${2:-}"; GENERATE_AUDIO="$2"; shift 2 ;;
    --watermark)     WATERMARK=true; shift ;;
    --web-search)    WEB_SEARCH=true; shift ;;
    --api-key)       require_arg "$1" "${2:-}"; API_KEY="$2"; API_KEY_FROM_FLAG=true; shift 2 ;;
    --base-url)      require_arg "$1" "${2:-}"; BASE_URL="$2"; shift 2 ;;
    --poll-interval) require_arg "$1" "${2:-}"; POLL_INTERVAL="$2"; shift 2 ;;
    --max-wait)      require_arg "$1" "${2:-}"; MAX_WAIT="$2"; shift 2 ;;
    --task-id)       require_arg "$1" "${2:-}"; TASK_ID="$2"; shift 2 ;;
    --download)      require_arg "$1" "${2:-}"; DOWNLOAD_DIR="$2"; shift 2 ;;
    -*)              echo "Unknown option: $1" >&2; exit 1 ;;
    *)               PROMPT="$1"; shift ;;
  esac
done

if [[ -z "$PROMPT" && -z "$TASK_ID" ]]; then
  echo "Usage: seedance.sh \"prompt\" [options]" >&2
  echo "" >&2
  echo "Models:" >&2
  echo "  doubao-seedance-2-0-260128       Quality (720p, multi-modal, up to 15s)" >&2
  echo "  doubao-seedance-2-0-fast-260128  Fast + cheap (default)" >&2
  echo "" >&2
  echo "Environment:" >&2
  echo "  SEEDANCE_API_KEY    API key (required)" >&2
  echo "  SEEDANCE_BASE_URL   Base URL (default: $DEFAULT_BASE_URL)" >&2
  echo "  SEEDANCE_MODEL      Default model (default: doubao-seedance-2-0-fast-260128)" >&2
  exit 1
fi

if [[ -z "$API_KEY" ]]; then
  echo "❌ Set SEEDANCE_API_KEY or use --api-key" >&2
  exit 1
fi

# Base URLs are printed in progress and recovery output. Authentication belongs
# in the API-key input, not URL userinfo, queries, or fragments.
URL_AUTHORITY="${BASE_URL#*://}"
URL_AUTHORITY="${URL_AUTHORITY%%/*}"
if [[ ( "$BASE_URL" != http://* && "$BASE_URL" != https://* ) ||
      -z "$URL_AUTHORITY" || "$URL_AUTHORITY" == *@* ||
      "$BASE_URL" == *\?* || "$BASE_URL" == *\#* ]]; then
  echo "❌ Use a credential-free HTTP(S) base URL without userinfo, query, or fragment; supply authentication through SEEDANCE_API_KEY or --api-key." >&2
  exit 1
fi

# --- Input validation ---
for value in "$MAX_WAIT" "$POLL_INTERVAL"; do
  if [[ ! "$value" =~ ^[0-9]{1,9}$ ]] || (( 10#$value < 1 )); then
    echo "❌ --max-wait and --poll-interval must be positive integers." >&2
    exit 1
  fi
done
MAX_WAIT=$((10#$MAX_WAIT))
POLL_INTERVAL=$((10#$POLL_INTERVAL))
if [[ -n "$TASK_ID" && ! "$TASK_ID" =~ ^[A-Za-z0-9_-]+$ ]]; then
  echo "❌ Invalid task ID." >&2
  exit 1
fi

HAS_FRAME=$([[ -n "$FIRST_IMAGE" || -n "$LAST_IMAGE" ]] && echo true || echo false)
HAS_REF=$([[ ${#REF_IMAGES[@]} -gt 0 || ${#REF_VIDEOS[@]} -gt 0 || ${#REF_AUDIOS[@]} -gt 0 ]] && echo true || echo false)

# --last-image requires --image
if [[ -n "$LAST_IMAGE" && -z "$FIRST_IMAGE" ]]; then
  echo "❌ --last-image requires --image (first frame)." >&2
  exit 1
fi

# First-frame mode and reference mode are mutually exclusive
if [[ "$HAS_FRAME" == "true" && "$HAS_REF" == "true" ]]; then
  echo "❌ Cannot mix first/last frame (--image/--last-image) with reference inputs (--ref-image/--ref-video/--ref-audio)." >&2
  echo "   These are mutually exclusive modes." >&2
  exit 1
fi

# Audio cannot be used alone — must include at least one image or video
if [[ ${#REF_AUDIOS[@]} -gt 0 && ${#REF_IMAGES[@]} -eq 0 && ${#REF_VIDEOS[@]} -eq 0 && -z "$FIRST_IMAGE" ]]; then
  echo "❌ --ref-audio cannot be used alone. Include at least one image (--ref-image/--image) or video (--ref-video)." >&2
  exit 1
fi

# --web-search is text-to-video only
if [[ "$WEB_SEARCH" == "true" && ("$HAS_FRAME" == "true" || "$HAS_REF" == "true") ]]; then
  echo "❌ --web-search is only supported for pure text-to-video. Remove image/video/audio inputs." >&2
  exit 1
fi

# --- Model validation: only Seedance 2.0 series allowed ---
if [[ -z "$TASK_ID" && "$MODEL" != *"seedance-2-0"* ]]; then
  echo "❌ Only Seedance 2.0 models are supported." >&2
  echo "   Allowed: doubao-seedance-2-0-260128 (quality) or doubao-seedance-2-0-fast-260128 (fast)" >&2
  echo "   Got: $MODEL" >&2
  exit 1
fi

TASKS_URL="${BASE_URL}/api/v3/contents/generations/tasks"

# --- Helper: extract video URL from response (handles both object and array content) ---
extract_video_url() {
  local json="$1"
  echo "$json" | jq -r '
    # Try object form: .content.video_url (string)
    (.content.video_url // null) as $obj_url |
    # Try array form: .content[0].video_url.url (string)
    (if (.content | type) == "array" then .content[0].video_url.url // null else null end) as $arr_url |
    # Try legacy: .output.video_url
    (.output.video_url // null) as $legacy_url |
    ($obj_url // $arr_url // $legacy_url // empty)
  ' 2>/dev/null || echo ""
}

# Report only the provider's diagnostic fields, never the full response body.
api_diagnostic() {
  local message
  message=$(printf '%s' "$RESULT" | jq -r '
    .error as $error |
    if ($error | type) == "object" then
      [$error.code, $error.message] | map(select(type == "string")) | join(": ")
    elif ($error | type) == "string" then $error
    else "" end | gsub("[[:cntrl:]]"; " ")
  ' 2>/dev/null || true)
  message=${message//"$API_KEY"/[REDACTED]}
  [[ -z "$message" ]] || printf '   Provider: %.1000s\n' "$message" >&2
}

# One bounded HTTP attempt. GET retries belong to the polling loop;
# a creation POST is never replayed automatically after an ambiguous failure.
RESPONSE_FILE=$(mktemp "${TMPDIR:-/tmp}/seedance.XXXXXX")
trap 'rm -f "$RESPONSE_FILE"' EXIT
SECONDS=0
RESULT=""
HTTP_STATUS=""
request() {
  local remaining=$((MAX_WAIT - SECONDS))
  [[ $remaining -gt 0 ]] || return 2
  local connect_timeout=10 rc=0
  [[ $remaining -lt $connect_timeout ]] && connect_timeout=$remaining
  HTTP_STATUS=$(curl -q --retry 0 --connect-timeout "$connect_timeout" \
    --max-time "$remaining" -sS -o "$RESPONSE_FILE" -w '%{http_code}' "$@") || rc=$?
  RESULT=$(<"$RESPONSE_FILE")
  if [[ $rc -ne 0 ]]; then
    return 2
  fi
  case "$HTTP_STATUS" in
    2??) return 0 ;;
    408|429|5??) return 2 ;;
    *) echo "❌ HTTP $HTTP_STATUS; request rejected." >&2; api_diagnostic; return 1 ;;
  esac
}

resume_hint() {
  echo "   Task ID: $TASK_ID" >&2
  printf '   Resume:' >&2
  printf ' %q' "${BASH_SOURCE[0]}" --task-id "$TASK_ID" --base-url "$BASE_URL" \
    --max-wait "$MAX_WAIT" --poll-interval "$POLL_INTERVAL" >&2
  if [[ -n "$DOWNLOAD_DIR" ]]; then
    printf ' %q' --download "$DOWNLOAD_DIR" >&2
  fi
  printf '\n' >&2
  if [[ "$API_KEY_FROM_FLAG" == true ]]; then
    echo "   Credentials came from --api-key. Securely set SEEDANCE_API_KEY to the same value before resuming; the command omits secrets." >&2
  else
    echo "   Keep the same credentials in SEEDANCE_API_KEY; the command omits secrets." >&2
  fi
}

if [[ -z "$TASK_ID" ]]; then
  # Build content array as JSON
  CONTENT='[]'

  # Add text prompt
  CONTENT=$(echo "$CONTENT" | jq --arg t "$PROMPT" '. + [{"type":"text","text":$t}]')

  # Determine mode and add media
  if [[ -n "$FIRST_IMAGE" && -n "$LAST_IMAGE" ]]; then
    # First + Last frame mode (2.0 only, validated above)
    CONTENT=$(echo "$CONTENT" | jq --arg u "$FIRST_IMAGE" \
      '. + [{"type":"image_url","image_url":{"url":$u},"role":"first_frame"}]')
    CONTENT=$(echo "$CONTENT" | jq --arg u "$LAST_IMAGE" \
      '. + [{"type":"image_url","image_url":{"url":$u},"role":"last_frame"}]')
  elif [[ -n "$FIRST_IMAGE" ]]; then
    # First frame mode (2.0 only, validated above)
    CONTENT=$(echo "$CONTENT" | jq --arg u "$FIRST_IMAGE" \
      '. + [{"type":"image_url","image_url":{"url":$u},"role":"first_frame"}]')
  else
    # Multi-modal reference mode (2.0 only, validated above)
    for img in "${REF_IMAGES[@]+"${REF_IMAGES[@]}"}"; do
      CONTENT=$(echo "$CONTENT" | jq --arg u "$img" \
        '. + [{"type":"image_url","image_url":{"url":$u},"role":"reference_image"}]')
    done
    for vid in "${REF_VIDEOS[@]+"${REF_VIDEOS[@]}"}"; do
      CONTENT=$(echo "$CONTENT" | jq --arg u "$vid" \
        '. + [{"type":"video_url","video_url":{"url":$u},"role":"reference_video"}]')
    done
    for aud in "${REF_AUDIOS[@]+"${REF_AUDIOS[@]}"}"; do
      CONTENT=$(echo "$CONTENT" | jq --arg u "$aud" \
        '. + [{"type":"audio_url","audio_url":{"url":$u},"role":"reference_audio"}]')
    done
  fi

  # Build request body
  BODY=$(jq -n \
    --arg model "$MODEL" \
    --argjson content "$CONTENT" \
    --arg resolution "$RESOLUTION" \
    --arg ratio "$RATIO" \
    --argjson duration "$DURATION" \
    --argjson watermark "$WATERMARK" \
    --argjson generate_audio "$GENERATE_AUDIO" \
    '{model:$model, content:$content, resolution:$resolution, ratio:$ratio, duration:$duration, watermark:$watermark, generate_audio:$generate_audio}')

  # Add web search tool if requested (2.0 only, validated above)
  if [[ "$WEB_SEARCH" == "true" ]]; then
    BODY=$(echo "$BODY" | jq '. + {tools:[{type:"web_search"}]}')
  fi

  echo "🎬 Creating video generation task..."
  echo "   Model: $MODEL"
  echo "   Base URL: $BASE_URL"
  echo "   Resolution: $RESOLUTION | Ratio: $RATIO | Duration: ${DURATION}s"
  echo "   Audio: $GENERATE_AUDIO"

  # Submit once. A transport failure may occur after the server accepted the task.
  create_rc=0
  request -X POST "$TASKS_URL" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $API_KEY" \
    -d "$BODY" || create_rc=$?
  if [[ $create_rc -eq 1 ]]; then
    echo "❌ Creation was rejected; correct the reported request error before submitting again." >&2
    exit 1
  elif [[ $create_rc -ne 0 ]]; then
    api_diagnostic
    echo "❌ Creation was not confirmed. Check the provider task list before submitting again." >&2
    exit 1
  fi
  TASK_ID=$(printf '%s' "$RESULT" | jq -er '(.id // .task_id) | select(type == "string" and test("^[A-Za-z0-9_-]+$"))' 2>/dev/null || true)
  if [[ -z "$TASK_ID" ]]; then
    echo "❌ Creation response has no valid task ID. Check the provider task list before submitting again." >&2
    exit 1
  fi
  echo "✅ Task created: $TASK_ID"
fi

echo "⏳ Querying task $TASK_ID (interval: ${POLL_INTERVAL}s, budget: ${MAX_WAIT}s)..."
CONSECUTIVE_ERRORS=0
while [[ $SECONDS -lt $MAX_WAIT ]]; do
  rc=0
  request "$TASKS_URL/$TASK_ID" -H "Authorization: Bearer $API_KEY" || rc=$?
  if [[ $rc -eq 1 ]]; then
    resume_hint
    exit 1
  fi
  STATUS=""
  if [[ $rc -eq 0 ]]; then
    STATUS=$(printf '%s' "$RESULT" | jq -er '.status | select(type == "string")' 2>/dev/null || true)
  fi
  case "$STATUS" in
    succeeded)
      VIDEO_URL=$(extract_video_url "$RESULT")
      if [[ -z "$VIDEO_URL" ]]; then
        echo "❌ Task succeeded but the result contains no video URL." >&2
        resume_hint
        exit 1
      fi
      TOKENS=$(printf '%s' "$RESULT" | jq -r '.usage.total_tokens // "N/A"')
      ACTUAL_DURATION=$(printf '%s' "$RESULT" | jq -r '.duration // "N/A"')
      echo "🎉 Video generated: $VIDEO_URL"
      echo "   Duration: ${ACTUAL_DURATION}s | Tokens: $TOKENS"
      echo "   URL expires in 24 hours — download promptly"
      if [[ -n "$DOWNLOAD_DIR" ]]; then
        remaining=$((MAX_WAIT - SECONDS))
        if [[ $remaining -le 0 ]]; then
          echo "❌ Download budget exhausted; resume the same task." >&2
          resume_hint
          exit 1
        fi
        mkdir -p "$DOWNLOAD_DIR"
        if curl -q --retry 0 --connect-timeout "$remaining" --max-time "$remaining" \
          --fail -sS -o "${DOWNLOAD_DIR}/${TASK_ID}.mp4" "$VIDEO_URL"; then
          echo "✅ Saved: ${DOWNLOAD_DIR}/${TASK_ID}.mp4"
        else
          echo "❌ Download failed; resume the same task." >&2
          resume_hint
          exit 1
        fi
      fi
      exit 0
      ;;
    failed|cancelled|canceled|expired)
      echo "❌ Task $STATUS. Task ID: $TASK_ID" >&2
      api_diagnostic
      exit 1
      ;;
    queued|running)
      CONSECUTIVE_ERRORS=0
      printf '[%ds] Status: %s\n' "$SECONDS" "$STATUS"
      ;;
    *)
      CONSECUTIVE_ERRORS=$((CONSECUTIVE_ERRORS + 1))
      if [[ $CONSECUTIVE_ERRORS -ge 5 ]]; then
        echo "❌ Five consecutive transport, HTTP, or invalid-status errors." >&2
        resume_hint
        exit 1
      fi
      echo "⚠️ Query error ($CONSECUTIVE_ERRORS/5); retrying within the remaining budget." >&2
      ;;
  esac
  remaining=$((MAX_WAIT - SECONDS))
  [[ $remaining -gt 0 ]] || break
  delay=$POLL_INTERVAL
  [[ $remaining -lt $delay ]] && delay=$remaining
  sleep "$delay"
done

echo "⏰ Call budget exhausted after ${MAX_WAIT}s. The task may still be running." >&2
resume_hint
exit 1
