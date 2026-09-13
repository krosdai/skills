---
name: video-generation
description: Generate or edit videos with Seedance through the Volcengine Ark API, including animating images and extending clips. Use for requested video generation or explicit Seedance workflows.
---

# Video Generation — Seedance 2.0

## Setup

- **Default Base URL:** `https://ark.cn-beijing.volces.com`
- **API Key:** From [Volcengine Console](https://console.volcengine.com/ark/region:ark+cn-beijing/apikey)

## Models

| Model             | ID                                | Best For               |
| ----------------- | --------------------------------- | ---------------------- |
| Seedance 2.0      | `doubao-seedance-2-0-260128`      | Maximum quality        |
| Seedance 2.0 Fast | `doubao-seedance-2-0-fast-260128` | Speed + cost (default) |

Both models: max 720p, max 15s, full multi-modal support.

## Environment Variables

| Variable            | Required | Default                             | Description                     |
| ------------------- | -------- | ----------------------------------- | ------------------------------- |
| `SEEDANCE_API_KEY`  | ✅       | —                                   | API key for authentication      |
| `SEEDANCE_BASE_URL` | —        | `https://ark.cn-beijing.volces.com` | Base URL (override for proxies) |
| `SEEDANCE_MODEL`    | —        | `doubao-seedance-2-0-fast-260128`   | Default model ID                |

## Quick Start

### Create Task

```bash
curl -X POST ${SEEDANCE_BASE_URL:-https://ark.cn-beijing.volces.com}/api/v3/contents/generations/tasks \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $SEEDANCE_API_KEY" \
  -d '{
    "model": "doubao-seedance-2-0-fast-260128",
    "content": [{"type": "text", "text": "A cat playing piano, cinematic lighting"}],
    "resolution": "720p",
    "ratio": "16:9",
    "duration": 5,
    "watermark": false
  }'
```

### Poll Result

```bash
curl ${SEEDANCE_BASE_URL:-https://ark.cn-beijing.volces.com}/api/v3/contents/generations/tasks/{task_id} \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $SEEDANCE_API_KEY"
```

Tasks are asynchronous. Poll within a real elapsed-time budget and inspect HTTP
errors and task status. Stop on success or a terminal failure; retry only transient
query errors within the budget. On timeout retain the task ID and query that same
task, rather than submitting again. A successful video URL is valid for 24 hours.

### Response Format

**⚠️ `content` is an object, not an array.** The video URL is at `content.video_url`:

```json
{
  "id": "cgt-...",
  "model": "doubao-seedance-2-0-fast-260128",
  "status": "succeeded",
  "content": {
    "video_url": "https://..."
  },
  "usage": { "completion_tokens": 108900, "total_tokens": 108900 },
  "duration": 5,
  "framespersecond": 24,
  "resolution": "720p",
  "ratio": "16:9"
}
```

## Generation Modes

| Mode                  | Content Array                                                                        | Notes                                                |
| --------------------- | ------------------------------------------------------------------------------------ | ---------------------------------------------------- |
| Text→Video            | `[{type:"text", text:"..."}]`                                                        | Prompt only                                          |
| First Frame           | `[{type:"text",...}, {type:"image_url", image_url:{url:"..."}, role:"first_frame"}]` |                                                      |
| First+Last Frame      | Two `image_url` with roles `first_frame` + `last_frame`                              |                                                      |
| Multi-modal Reference | Images (`reference_image`) + Videos (`reference_video`) + Audio (`reference_audio`)  | Up to 9 images, 3 videos (≤15s total), 3 audio clips |
| Edit Video            | Text + reference_image + reference_video                                             | "Replace X in the video with Y from the image"       |
| Extend Video          | Text + multiple reference_videos                                                     | Stitch/extend narrative across clips                 |

**⚠️ Modes are mutually exclusive:** first_frame/last_frame vs reference_image/reference_video cannot be mixed.

## Key Parameters

| Parameter        | Values                                                          | Default                         | Notes                              |
| ---------------- | --------------------------------------------------------------- | ------------------------------- | ---------------------------------- |
| `model`          | `doubao-seedance-2-0-260128`, `doubao-seedance-2-0-fast-260128` | fast                            | Required                           |
| `resolution`     | `480p`, `720p`                                                  | `720p`                          | Max 720p                           |
| `ratio`          | `21:9`, `16:9`, `4:3`, `1:1`, `3:4`, `9:16`, `adaptive`         | API: `adaptive`; script: `16:9` |                                    |
| `duration`       | 4–15 (int), or -1 (auto)                                        | 5                               | Seconds                            |
| `generate_audio` | true/false                                                      | true                            | Sync audio/speech/music generation |
| `watermark`      | true/false                                                      | —                               | —                                  |
| `tools`          | `[{"type":"web_search"}]`                                       | —                               | Text-to-video only                 |

## Script

Use `scripts/seedance.sh` for one-shot generation:

```bash
# Text-to-video (default: 2.0 Fast, 720p)
scripts/seedance.sh "A cat playing piano, cinematic lighting"

# Image-to-video (first frame)
scripts/seedance.sh "The character walks forward" --image https://example.com/photo.jpg

# Max quality with 2.0
scripts/seedance.sh "prompt" --model doubao-seedance-2-0-260128 --ratio 9:16 --duration 10

# Download to directory
scripts/seedance.sh "prompt" --download /tmp/videos

# Resume an existing task without another generation request
scripts/seedance.sh --task-id cgt-example --max-wait 600
```

Respects `SEEDANCE_API_KEY`, `SEEDANCE_BASE_URL`, and `SEEDANCE_MODEL` environment variables.
Use a credential-free HTTP(S) base URL without userinfo, query parameters, or
fragments. Pass authentication separately through the API-key input; endpoints
appear in progress and recovery output.

The script validates generation models, bounds HTTP calls and waits by elapsed
time, and retries transient queries or invalid responses up to five consecutive
errors. It submits a creation POST only once: after an ambiguous creation failure,
check the provider task list before trying again. Resume with `--task-id` to query
or download an existing result. Permanent HTTP errors and terminal task failures
return immediately with the task ID when known.

## Prompt Tips

- Chinese or English. Keep under 500 Chinese chars / 1000 English words.
- Too much detail → model ignores parts. Focus on key elements.
- For audio generation: put dialogue in double quotes → `男人说："你好"`
- Reference inputs by their order in the content array.

## Detailed API Reference

See `references/volcengine-api.md` for full parameter specs, input constraints, pixel tables, and rate limits.
