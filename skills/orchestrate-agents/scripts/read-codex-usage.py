#!/usr/bin/env python3
"""Read the newest Codex rate-limit snapshot from one or more CODEX_HOME profiles."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


def parse_timestamp(value: Any) -> float | None:
    if isinstance(value, (int, float)):
        return float(value)
    if not isinstance(value, str):
        return None

    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def latest_rate_limits(sessions_dir: Path) -> tuple[dict[str, Any], Path] | None:
    try:
        session_files = list(sessions_dir.rglob("*.jsonl"))
    except OSError:
        return None

    latest: tuple[float, dict[str, Any], Path] | None = None
    for path in session_files:
        try:
            with path.open(encoding="utf-8", errors="replace") as session:
                for line in session:
                    try:
                        event = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    if not isinstance(event, dict):
                        continue

                    payload = event.get("payload")
                    if not isinstance(payload, dict):
                        continue
                    if payload.get("type") != "token_count" or not isinstance(
                        payload.get("rate_limits"), dict
                    ):
                        continue

                    observed_at = parse_timestamp(event.get("timestamp"))
                    if observed_at is None:
                        continue
                    if latest is None or observed_at > latest[0]:
                        latest = (observed_at, event, path)
        except OSError:
            continue

    if latest is None:
        return None
    return latest[1], latest[2]


def login_mode(codex_home: Path, codex: str) -> str:
    environment = os.environ.copy()
    environment["CODEX_HOME"] = str(codex_home)
    try:
        result = subprocess.run(
            [codex, "login", "status"],
            check=False,
            capture_output=True,
            env=environment,
            text=True,
            timeout=15,
        )
    except (OSError, subprocess.TimeoutExpired):
        return "unavailable"

    status_text = f"{result.stdout}\n{result.stderr}"
    if result.returncode != 0:
        return "unavailable"
    return "chatgpt" if "chatgpt" in status_text.lower() else "other"


def remaining_percent(window: Any) -> float | None:
    if not isinstance(window, dict):
        return None
    used = window.get("used_percent")
    if not isinstance(used, (int, float)):
        return None
    return max(0.0, min(100.0, 100.0 - float(used)))


def sample_profile(
    profile: str,
    codex_home: Path,
    codex: str,
    max_age: int,
) -> dict[str, Any]:
    mode = login_mode(codex_home, codex)
    snapshot = latest_rate_limits(codex_home / "sessions")
    sampled_at = datetime.now(timezone.utc).timestamp()
    record: dict[str, Any] = {
        "profile": profile,
        "codex_home": str(codex_home),
        "sampled_at": datetime.fromtimestamp(sampled_at, timezone.utc).isoformat(),
        "login_mode": mode,
        "status": "no_snapshot",
        "schedulable": False,
        "snapshot_at": None,
        "snapshot_age_seconds": None,
        "session_path": None,
        "effective_remaining_percent": None,
        "rate_limits": None,
    }

    if snapshot is None:
        record["status"] = "auth_error" if mode == "unavailable" else "no_snapshot"
        if mode == "other":
            record["status"] = "not_chatgpt"
        return record

    event, session_path = snapshot
    observed_at = parse_timestamp(event.get("timestamp"))
    if observed_at is None:
        record["status"] = "invalid_snapshot"
        return record

    rate_limits = event["payload"]["rate_limits"]
    windows = [rate_limits.get("primary"), rate_limits.get("secondary")]
    remaining = [value for value in map(remaining_percent, windows) if value is not None]
    reset_times = [
        window.get("resets_at")
        for window in windows
        if isinstance(window, dict) and isinstance(window.get("resets_at"), (int, float))
    ]
    age_seconds = max(0, int(sampled_at - observed_at))
    reset_elapsed = any(float(reset_at) <= sampled_at for reset_at in reset_times)
    stale = age_seconds > max_age or reset_elapsed
    limit_reached = rate_limits.get("rate_limit_reached_type") is not None
    spend_control = bool(rate_limits.get("spend_control_reached"))

    status = "ok"
    if mode == "unavailable":
        status = "auth_error"
    elif mode != "chatgpt":
        status = "not_chatgpt"
    elif not remaining:
        status = "invalid_snapshot"
    elif stale:
        status = "stale"
    elif limit_reached or spend_control:
        status = "exhausted"

    record.update(
        {
            "status": status,
            "schedulable": status == "ok",
            "snapshot_at": event.get("timestamp"),
            "snapshot_age_seconds": age_seconds,
            "session_path": str(session_path),
            "effective_remaining_percent": min(remaining) if remaining else None,
            "rate_limits": rate_limits,
        }
    )
    return record


def parse_home(value: str) -> tuple[str, Path]:
    profile, separator, raw_path = value.partition("=")
    if not separator or not profile or not raw_path:
        raise argparse.ArgumentTypeError("expected PROFILE=CODEX_HOME")
    return profile, Path(raw_path).expanduser().resolve()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--home",
        action="append",
        required=True,
        type=parse_home,
        metavar="PROFILE=CODEX_HOME",
        help="profile label and its Codex home; repeat for every app-server",
    )
    parser.add_argument("--codex", default="codex", help="Codex executable (default: codex)")
    parser.add_argument(
        "--max-age",
        required=True,
        type=int,
        metavar="SECONDS",
        help="maximum schedulable snapshot age",
    )
    args = parser.parse_args()
    if args.max_age < 0:
        parser.error("--max-age must be non-negative")

    for profile, codex_home in args.home:
        print(
            json.dumps(
                sample_profile(profile, codex_home, args.codex, args.max_age),
                separators=(",", ":"),
                sort_keys=True,
            )
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
