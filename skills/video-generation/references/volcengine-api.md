# Volcengine Seedance API Reference

## Endpoints

All endpoints are relative to the base URL (default: `https://ark.cn-beijing.volces.com`).
Override with `SEEDANCE_BASE_URL` environment variable for proxies/gateways.

- **Create Task:** `POST {base}/api/v3/contents/generations/tasks`
- **Query Task:** `GET {base}/api/v3/contents/generations/tasks/{id}`
- **List Tasks:** `GET {base}/api/v3/contents/generations/tasks?page_num=N&page_size=M`

Auth: `Authorization: Bearer $SEEDANCE_API_KEY`

## Models

| Model             | ID                                | Best For           |
| ----------------- | --------------------------------- | ------------------ |
| Seedance 2.0      | `doubao-seedance-2-0-260128`      | Maximum quality    |
| Seedance 2.0 fast | `doubao-seedance-2-0-fast-260128` | Speed + cost       |
| Seedance 1.5 pro  | `doubao-seedance-1-5-pro-251215`  | 1080p, sample mode |

### Feature Matrix (2.0 vs older)

Only Seedance 2.0 / 2.0 fast support:

- Multi-modal reference (images + videos + audio)
- Video editing (replace elements)
- Video extension (stitch clips)
- Web search enhancement
- Up to 15s duration

Older models (1.5, 1.0) support 1080p but lack multi-modal features.

### Seedance 1.5 Pro Specifics

- Max resolution: 1080p
- Max duration: 10s (vs 15s for 2.0)
- Supported modes: text-to-video, first-frame image-to-video
- NOT supported: first+last frame, multi-modal reference, video editing/extension, web search, audio generation
- `generate_audio` parameter should NOT be sent (ignored/may error)

## Content Types

### Text

```json
{ "type": "text", "text": "prompt string" }
```

- Chinese: ≤500 chars. English: ≤1000 words.
- Too much detail → model ignores parts.

### Image

```json
{
  "type": "image_url",
  "image_url": { "url": "<public URL | data:image/png;base64,... | asset://ASSET_ID>" },
  "role": "first_frame | last_frame | reference_image"
}
```

**Constraints:**

- Formats: jpeg, png, webp, bmp, tiff, gif
- Aspect ratio (W/H): 0.4–2.5
- Dimensions: 300–6000px per side
- Size: <30MB per image; request body <64MB
- Counts: first frame = 1; first+last = 2; reference = 1–9

### Video

```json
{
  "type": "video_url",
  "video_url": { "url": "<public URL | asset://ASSET_ID>" },
  "role": "reference_video"
}
```

**Constraints:**

- Formats: mp4, mov
- Resolution: 480p or 720p
- Duration: 2–15s per clip; total ≤15s across up to 3 clips
- Aspect ratio: 0.4–2.5
- Dimensions: 300–6000px per side
- Pixel count: 409,600–927,408 (e.g. 640×640 to 834×1112)
- Size: <50MB per video
- FPS: 24–60

### Audio

```json
{
  "type": "audio_url",
  "audio_url": { "url": "<public URL | data:audio/wav;base64,... | asset://ASSET_ID>" },
  "role": "reference_audio"
}
```

**Constraints:**

- Formats: wav, mp3
- Duration: 2–15s per clip; total ≤15s across up to 3 clips
- Size: <15MB per audio; request body <64MB
- Output is always mono

**⚠️ Audio cannot be used alone — must include at least 1 image or video.**

## Mutually Exclusive Modes

These three modes **cannot be mixed** in a single request:

1. **First frame** (`role: first_frame`)
2. **First + last frame** (`role: first_frame` + `role: last_frame`)
3. **Multi-modal reference** (`role: reference_image` / `reference_video` / `reference_audio`)

Workaround: In multi-modal mode, use the prompt to instruct the model to use a reference image as the first/last frame.

## Parameters

| Param            | Type     | Values                                                  | Default    | Notes                                |
| ---------------- | -------- | ------------------------------------------------------- | ---------- | ------------------------------------ |
| `model`          | string   | See models table                                        | —          | Required                             |
| `content`        | object[] | See content types                                       | —          | Required                             |
| `resolution`     | string   | `480p`, `720p`, `1080p`                                 | `720p`     | 2.0 max 720p; 1.5 Pro supports 1080p |
| `ratio`          | string   | `21:9`, `16:9`, `4:3`, `1:1`, `3:4`, `9:16`, `adaptive` | `adaptive` |                                      |
| `duration`       | int      | 4–15, or -1 (auto)                                      | 5          | -1 = model decides                   |
| `generate_audio` | bool     |                                                         | true (2.0) | Sync audio with visuals              |
| `watermark`      | bool     |                                                         | —          |                                      |
| `tools`          | object[] | `[{"type":"web_search"}]`                               | —          | 2.0 only, text-to-video only         |

## Resolution × Ratio Pixel Table

### 480p

| Ratio | Pixels  |
| ----- | ------- |
| 16:9  | 864×496 |
| 4:3   | 752×560 |
| 1:1   | 640×640 |
| 3:4   | 560×752 |
| 9:16  | 496×864 |
| 21:9  | 992×432 |

### 720p

| Ratio | Pixels   |
| ----- | -------- |
| 16:9  | 1280×720 |
| 4:3   | 1112×834 |
| 1:1   | 960×960  |
| 3:4   | 834×1112 |
| 9:16  | 720×1280 |
| 21:9  | 1470×630 |

## Rate Limits

|             | 2.0 / 2.0 fast | 1.5 pro | 1.0 pro | 1.0 lite |
| ----------- | -------------- | ------- | ------- | -------- |
| RPM         | 600            | 600     | 600     | 300      |
| Concurrency | 10             | 10      | 10      | 5        |

## Response Fields

- `id` — task ID
- `status` — `running` / `succeeded` / `failed`
- `content.video_url` — output video URL string (valid 24h). **⚠️ `content` is an object, not an array.**
- `usage.completion_tokens` — output tokens
- `usage.total_tokens` — total tokens
- `usage.tool_usage.web_search` — search call count (if enabled)
- `duration` — actual video duration (when `duration=-1`)
- `ratio` — actual ratio (when `ratio=adaptive`)
- `framespersecond` — output FPS (typically 24)
- `seed` — random seed used
- `resolution` — actual resolution used

## Virtual Avatar Assets

Volcengine provides a public avatar library for consistent character generation.

- Browse: https://console.volcengine.com/ark/region:ark+cn-beijing/experience/vision?modelId=doubao-seedance-2-0-260128
- Use in API: `asset://asset-YYYYMMDDHHMMSS-xxxxx`
- First use requires agreeing to avatar TOS in the experience center

Custom avatars (private): submit via sales representative with compliance materials.
