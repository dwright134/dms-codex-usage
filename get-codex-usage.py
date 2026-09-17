#!/usr/bin/env python3
"""Collect live Codex quotas and estimate local usage at standard API rates."""

import datetime as dt
import json
import os
from pathlib import Path
import selectors
import shutil
import subprocess
import time

VERSION = "0.1.1"
WEEK_MINUTES = 10080
FIVE_HOURS = 18000
LONG_CONTEXT = 272000

# USD per million text tokens: input, cached input, cache write, output.
PRICES = {
    "gpt-6-astra": (10.00, 1.00, 12.50, 50.00),
    "gpt-5.6-sol": (4.00, 0.40, 5.00, 20.00),
    "gpt-5.6": (4.00, 0.40, 5.00, 20.00),
    "gpt-5.6-terra": (2.00, 0.20, 2.50, 12.00),
    "gpt-5.6-luna": (0.20, 0.02, 0.25, 1.20),
    "gpt-5.5": (5.00, 0.50, 6.25, 30.00),
    "gpt-5.4": (2.50, 0.25, 3.125, 15.00),
}


def parse_time(value):
    return dt.datetime.fromisoformat(value.replace("Z", "+00:00"))


def read_json(path, default):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError, TypeError):
        return default


def write_json(path, value):
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        temp = path.with_suffix(path.suffix + ".tmp")
        temp.write_text(json.dumps(value, separators=(",", ":")))
        temp.replace(path)
    except OSError:
        pass


def price_for(model):
    if model in PRICES:
        return PRICES[model]
    for name in sorted(PRICES, key=len, reverse=True):
        if model.startswith(name + "-"):
            return PRICES[name]
    return None


def estimate_cost(model, parts):
    price = price_for(model)
    if not price:
        return None
    inp = max(0, parts.get("input_tokens", 0))
    cached = min(inp, max(0, parts.get("cached_input_tokens", 0)))
    written = min(inp - cached, max(0, parts.get("cache_write_input_tokens", 0)))
    uncached = max(0, inp - cached - written)
    out = max(0, parts.get("output_tokens", 0))
    input_mult = 2 if inp > LONG_CONTEXT else 1
    output_mult = 1.5 if inp > LONG_CONTEXT else 1
    return (uncached * price[0] * input_mult + cached * price[1] * input_mult
            + written * price[2] * input_mult + out * price[3] * output_mult) / 1_000_000


def delta(value, previous):
    return value - previous if value >= previous else value


def parse_session(path):
    days = {}
    quota = []
    previous = {}
    model = "Unknown"
    with path.open(errors="replace") as stream:
        for line in stream:
            try:
                row = json.loads(line)
                payload = row.get("payload") or {}
                if row.get("type") == "turn_context":
                    model = payload.get("model") or model
                    continue
                if payload.get("type") != "token_count":
                    continue
                stamp = parse_time(row["timestamp"])
                for key in ("primary", "secondary"):
                    window = (payload.get("rate_limits") or {}).get(key) or {}
                    if int(window.get("window_minutes") or 0) == WEEK_MINUTES:
                        quota.append({"at": int(stamp.timestamp()),
                                      "used": float(window.get("used_percent") or 0),
                                      "reset": int(window.get("resets_at") or 0)})
                totals = ((payload.get("info") or {}).get("total_token_usage") or {})
                if not isinstance(totals.get("total_tokens"), (int, float)):
                    continue
                fields = ("input_tokens", "cached_input_tokens", "cache_write_input_tokens",
                          "output_tokens", "reasoning_output_tokens", "total_tokens")
                parts = {}
                for field in fields:
                    value = totals.get(field, 0)
                    if isinstance(value, (int, float)) and value >= 0:
                        parts[field] = delta(float(value), previous.get(field, 0))
                        previous[field] = float(value)
                tokens = parts.get("total_tokens", 0)
                if tokens <= 0:
                    continue
                day = stamp.astimezone().date().isoformat()
                item = days.setdefault(day, {"tokens": 0, "cost": 0, "unpriced": 0,
                                             "parts": {}, "models": {}})
                timestamp = int(stamp.timestamp())
                item["first"] = min(item.get("first", timestamp), timestamp)
                cost = estimate_cost(model, parts)
                item["tokens"] += tokens
                item["cost"] += cost or 0
                item["unpriced"] += tokens if cost is None else 0
                for field, value in parts.items():
                    if field != "total_tokens":
                        item["parts"][field] = item["parts"].get(field, 0) + value
                target = item["models"].setdefault(model, {"tokens": 0, "cost": 0, "unpriced": 0})
                target["tokens"] += tokens
                target["cost"] += cost or 0
                target["unpriced"] += tokens if cost is None else 0
            except (ValueError, KeyError, TypeError, AttributeError, OverflowError):
                continue
    return {"days": days, "quota": quota}


def activity(root, cache_path, today=None):
    today = today or dt.datetime.now().astimezone().date()
    cache = read_json(cache_path, {})
    updated, days, points = {}, {}, []
    sessions = set()
    week_start = today - dt.timedelta(days=6)
    month_start = today.replace(day=1)
    roots = root if isinstance(root, (list, tuple)) else [root]
    paths = (path for candidate in roots if candidate.exists() for path in candidate.rglob("*.jsonl"))
    for path in paths:
        try:
            stat = path.stat()
            key = str(path)
            signature = [stat.st_size, stat.st_mtime_ns]
            saved = cache.get(key, {})
            if saved.get("signature") != signature:
                saved = {"signature": signature, **parse_session(path)}
            updated[key] = saved
            points.extend(p for p in saved.get("quota", []) if p.get("at", 0) > time.time() - 8 * 86400)
            active = False
            for day, source in saved.get("days", {}).items():
                target = days.setdefault(day, {"tokens": 0, "cost": 0, "unpriced": 0,
                                               "parts": {}, "models": {}})
                for field in ("tokens", "cost", "unpriced"):
                    target[field] += source.get(field, 0)
                if source.get("first"):
                    target["first"] = min(target.get("first", source["first"]), source["first"])
                for field, value in source.get("parts", {}).items():
                    target["parts"][field] = target["parts"].get(field, 0) + value
                for name, values in source.get("models", {}).items():
                    mt = target["models"].setdefault(name, {"tokens": 0, "cost": 0, "unpriced": 0})
                    for field in mt:
                        mt[field] += values.get(field, 0)
                active |= day >= week_start.isoformat() and source.get("tokens", 0) > 0
            if active:
                sessions.add(key)
        except OSError:
            continue
    write_json(cache_path, updated)

    def total(start, end):
        result = {"tokens": 0, "cost": 0, "unpriced": 0}
        for day, values in days.items():
            if start.isoformat() <= day <= end.isoformat():
                for field in result:
                    result[field] += values.get(field, 0)
        return result

    daily = []
    for offset in range(29, -1, -1):
        date = today - dt.timedelta(days=offset)
        values = days.get(date.isoformat(), {})
        daily.append({"day": date.strftime("%a"), "date": date.isoformat(),
                      "tokens": round(values.get("tokens", 0)),
                      "cost": round(values.get("cost", 0), 4)})
    today_total = total(today, today)
    week = total(week_start, today)
    month = total(month_start, today)
    prior = total(today - dt.timedelta(days=13), today - dt.timedelta(days=7))
    model_totals, breakdown = {}, {}
    for day, values in days.items():
        if week_start.isoformat() <= day <= today.isoformat():
            for field, value in values.get("parts", {}).items():
                breakdown[field] = breakdown.get(field, 0) + value
            for name, source in values.get("models", {}).items():
                target = model_totals.setdefault(name, {"tokens": 0, "cost": 0, "unpriced": 0})
                for field in target:
                    target[field] += source.get(field, 0)
    models = [{"name": name, "tokens": round(value["tokens"]),
               "cost": round(value["cost"], 4), "unpriced_tokens": round(value["unpriced"])}
              for name, value in sorted(model_totals.items(), key=lambda pair: pair[1]["tokens"], reverse=True)[:6]]
    return {"today": round(today_total["tokens"]), "week": round(week["tokens"]),
            "month": round(month["tokens"]), "today_cost": round(today_total["cost"], 4),
            "week_cost": round(week["cost"], 4), "month_cost": round(month["cost"], 4),
            "unpriced_week": round(week["unpriced"]), "previous_week": round(prior["tokens"]),
            "daily": daily[-7:], "daily30": daily, "sessions": len(sessions), "models": models,
            "breakdown_week": {k: round(v) for k, v in breakdown.items()},
            "first_activity": days.get(today.isoformat(), {}).get("first"), "quota_points": points}


def app_server(codex_home, timeout=12):
    executable = shutil.which("codex")
    if not executable:
        raise RuntimeError("codex executable not found")
    env = os.environ.copy()
    env["CODEX_HOME"] = str(codex_home)
    process = subprocess.Popen([executable, "app-server"], stdin=subprocess.PIPE,
                               stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                               text=True, bufsize=1, env=env)
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    results, deadline, requested = {}, time.monotonic() + timeout, False

    def send(value):
        process.stdin.write(json.dumps(value, separators=(",", ":")) + "\n")
        process.stdin.flush()

    try:
        send({"method": "initialize", "id": 0, "params": {"clientInfo": {
            "name": "dms_codex_usage", "title": "DMS Codex Usage", "version": VERSION}}})
        while time.monotonic() < deadline and not ({1, 2} <= results.keys()):
            events = selector.select(max(0.05, deadline - time.monotonic()))
            if not events:
                continue
            line = process.stdout.readline()
            if not line:
                break
            try:
                message = json.loads(line)
            except ValueError:
                continue
            if message.get("id") == 0 and not requested:
                send({"method": "initialized", "params": {}})
                send({"method": "account/rateLimits/read", "id": 1})
                send({"method": "account/usage/read", "id": 2})
                requested = True
            if message.get("id") in (1, 2):
                results[message["id"]] = message.get("result") or {}
        if 1 not in results:
            raise RuntimeError("rate-limit request timed out")
        return {"rate_limits": results[1], "usage": results.get(2, {})}
    finally:
        selector.close()
        process.terminate()
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()


def window(value):
    if not value:
        return None
    return {"used": float(value.get("usedPercent", value.get("used_percent", 0)) or 0),
            "minutes": int(value.get("windowDurationMins", value.get("window_minutes", 0)) or 0),
            "reset": int(value.get("resetsAt", value.get("resets_at", 0)) or 0)}


def pace(used, minutes, reset, now):
    if not minutes or not reset:
        return 0, ""
    elapsed = max(0, min(1, 1 - (reset - now) / (minutes * 60)))
    difference = used - elapsed * 100
    if used >= 100:
        return difference, "Quota reached"
    if difference >= 5:
        return difference, f"{round(difference)}% over pace"
    if difference <= -5:
        return difference, f"{round(-difference)}% under pace"
    return difference, "On pace"


def rounded_activity_start(timestamp):
    """Round a local activity timestamp to the nearest five-minute mark."""
    return int((timestamp + 150) // 300 * 300)


def clock_time(timestamp):
    value = dt.datetime.fromtimestamp(timestamp).astimezone().strftime("%I:%M %p")
    return value.lstrip("0")


def synthetic_five(weekly, points, now, activity_start=None):
    duration = weekly["minutes"] * 60
    start = weekly["reset"] - duration
    slot_start = rounded_activity_start(activity_start) if activity_start else (
        start + max(0, (now - start) // FIVE_HOURS) * FIVE_HOURS)
    slot_end = min(slot_start + FIVE_HOURS, weekly["reset"])
    candidates = sorted((p for p in points if p.get("reset") == weekly["reset"]
                         and slot_start - 600 <= p.get("at", 0) <= now), key=lambda p: p["at"])
    baseline = candidates[0] if candidates else {"at": now, "used": weekly["used"]}
    weekly_delta = max(0, weekly["used"] - baseline["used"])
    allocated = 100 * (slot_end - slot_start) / duration
    used = 100 * weekly_delta / allocated if allocated else 0
    coverage = max(0, min(now, slot_end) - slot_start)
    difference = used - 100 * coverage / max(1, slot_end - slot_start)
    if coverage < 300:
        label = "Collecting a five-hour baseline"
    elif difference >= 5:
        label = f"{round(difference)}% over pace"
    elif difference <= -5:
        label = f"{round(-difference)}% under pace"
    else:
        label = "On pace"
    return {"used": used, "minutes": round((slot_end - slot_start) / 60), "reset": slot_end,
            "pace_delta": difference, "pace": label, "estimated": True,
            "description": f"Pacing from {clock_time(slot_start)} to {clock_time(slot_end)} · "
                           f"estimated from {weekly_delta:.1f}% of weekly quota consumed"
                           + ("" if baseline["at"] <= slot_start + 600 else " · partial history")}


def emit(key, value):
    print(f"{key}={str(value).replace(chr(10), ' ').replace(chr(13), ' ')}")


def emit_bucket(identifier, label, value, now):
    difference, pace_label = (value.get("pace_delta"), value.get("pace"))
    if difference is None:
        difference, pace_label = pace(value["used"], value["minutes"], value["reset"], now)
    prefix = f"BUCKET_{identifier}_"
    emit(prefix + "GROUP", "Codex")
    emit(prefix + "GROUP_DESC", "Live account quota and local estimates")
    emit(prefix + "LABEL", label)
    emit(prefix + "WINDOW", value["minutes"])
    emit(prefix + "REMAINING", max(0, 1 - min(100, value["used"]) / 100))
    emit(prefix + "RESET", dt.datetime.fromtimestamp(value["reset"], dt.timezone.utc).isoformat() if value["reset"] else "")
    emit(prefix + "DESC", value.get("description", "Reported by Codex"))
    emit(prefix + "PACE", pace_label)
    emit(prefix + "PACE_DELTA", round(difference, 2))
    emit(prefix + "ESTIMATED", str(bool(value.get("estimated"))).lower())


def main():
    codex_home = Path(os.environ.get("CODEX_HOME", str(Path.home() / ".codex"))).expanduser()
    cache_root = Path(os.environ.get("XDG_CACHE_HOME", str(Path.home() / ".cache"))) / "dms-codex-usage"
    stats = activity([codex_home / "sessions", codex_home / "archived_sessions"],
                     cache_root / "activity-v4.json")
    now = int(time.time())
    live = False
    server_at = now
    try:
        server = app_server(codex_home)
        if not (server.get("rate_limits") or {}).get("rateLimits"):
            raise RuntimeError("empty response")
        write_json(cache_root / "account-v1.json", {"at": now, "data": server})
        live = True
    except (OSError, RuntimeError, subprocess.SubprocessError):
        cached_account = read_json(cache_root / "account-v1.json", {})
        server = cached_account.get("data", {})
        server_at = int(cached_account.get("at", now))
    limits = (server.get("rate_limits") or {}).get("rateLimits") or {}
    windows = [window(limits.get("primary")), window(limits.get("secondary"))]
    windows = [value for value in windows if value]
    weekly = next((value for value in windows if value["minutes"] == WEEK_MINUTES), None)
    if not weekly and windows:
        weekly = max(windows, key=lambda value: value["minutes"])
    actual_five = next((value for value in windows if value["minutes"] == 300), None)

    history_path = cache_root / "quota-history-v1.json"
    history = read_json(history_path, []) + stats.pop("quota_points", [])
    if live and weekly:
        history.append({"at": now, "used": weekly["used"], "reset": weekly["reset"]})
    unique = {(int(p.get("at", 0)), int(p.get("reset", 0)), float(p.get("used", 0))): p
              for p in history if p.get("at", 0) > now - 8 * 86400}
    history = sorted(unique.values(), key=lambda value: value["at"])
    write_json(history_path, history)
    if not weekly and history:
        latest = history[-1]
        weekly = {"used": float(latest["used"]), "minutes": WEEK_MINUTES,
                  "reset": int(latest["reset"]),
                  "description": "Last quota recorded in a local Codex session"}
    five = actual_five or (synthetic_five(weekly, history, now, stats.get("first_activity"))
                           if weekly else None)

    usage = server.get("usage") or {}
    summary = usage.get("summary") or {}
    stats.update({"lifetime_tokens": summary.get("lifetimeTokens"),
                  "peak_daily_tokens": summary.get("peakDailyTokens"),
                  "current_streak_days": summary.get("currentStreakDays"),
                  "estimate_label": "Estimated API equivalent", "pricing_version": "2026-09-17"})
    emit("STATS", json.dumps(stats, separators=(",", ":")))
    emit("GROUPS", "primary,secondary" if five and weekly else "primary" if five else "secondary" if weekly else "")
    emit("LOGGED_IN", str(bool(weekly or five)).lower())
    emit("PLAN", str(limits.get("planType") or "Codex").replace("_", " ").title())
    emit("UPDATED_AT", dt.datetime.fromtimestamp(server_at, dt.timezone.utc).isoformat())
    emit("LIVE", str(live).lower())
    emit("VERSION", VERSION)
    if five:
        emit_bucket("primary", "5h budget" if five.get("estimated") else "Five-hour limit", five, now)
    if weekly:
        emit_bucket("secondary", "Weekly limit", weekly, now)


if __name__ == "__main__":
    main()
