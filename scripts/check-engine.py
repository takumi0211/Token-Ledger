#!/usr/bin/env python3
"""Exercise the patched CodexBar CLI with isolated, fictional usage. No account probes."""
import datetime
import json
import math
import os
from pathlib import Path
import subprocess
import sys
import tempfile

engine = Path(sys.argv[1]).resolve()
now = datetime.datetime.now(datetime.timezone(datetime.timedelta(hours=9)))
previous_month = (now.replace(day=1) - datetime.timedelta(days=1)).date().isoformat()
days = [previous_month, now.date().isoformat()]


def write_rows(path, rows):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join(json.dumps(row, separators=(",", ":")) + "\n" for row in rows))


def codex_rows(model, speed, input_tokens):
    rows = []
    total = {"input_tokens": 0, "cached_input_tokens": 0, "output_tokens": 0}
    for index, day in enumerate(days):
        stamp = day + "T00:00:00+09:00"
        turn = f"fictional-turn-{index}"
        usage = {"input_tokens": input_tokens, "cached_input_tokens": input_tokens // 2, "output_tokens": 100}
        total = {key: total[key] + usage[key] for key in total}
        rows += [
            {"type": "event_msg", "timestamp": stamp, "payload": {"type": "thread_settings_applied", "thread_settings": {"service_tier": speed}}},
            {"type": "turn_context", "timestamp": stamp, "payload": {"model": model, "turn_id": turn}},
            {"type": "event_msg", "timestamp": stamp, "payload": {"type": "task_started", "turn_id": turn}},
            {"type": "token_usage_record", "timestamp": stamp, "payload": {
                "thread_id": "fictional-session", "session_id": "fictional-session", "turn_id": turn,
                "response_id": f"fictional-response-{index}", "model": model,
                "usage": usage, "turn_token_usage": usage, "thread_token_usage": total}},
            {"type": "event_msg", "timestamp": stamp, "payload": {"type": "task_complete", "turn_id": turn}},
        ]
    return [{"type": "session_meta", "timestamp": previous_month + "T00:00:00+09:00", "payload": {
        "id": "fictional-session", "source": "cli", "originator": "codex_cli_rs", "cwd": "/fictional"}}] + rows


def claude_rows(speed):
    rows = []
    for index, day in enumerate(days):
        for output in [1, 100]:
            rows.append({"type": "assistant", "timestamp": day + "T00:00:00+09:00", "sessionId": "fictional-session",
                "requestId": f"fictional-request-{index}", "message": {"id": f"fictional-message-{index}",
                "model": "claude-opus-5-5", "stop_reason": "end_turn", "usage": {
                    "input_tokens": 10000, "cache_read_input_tokens": 8000,
                    "cache_creation_input_tokens": 2000,
                    "cache_creation": {"ephemeral_1h_input_tokens": 2000, "ephemeral_5m_input_tokens": 0},
                    "output_tokens": output, "speed": speed}}})
    return rows


with tempfile.TemporaryDirectory(prefix="ledger-speed-check-") as temporary:
    root = Path(temporary)
    config = root / "config.json"
    config.write_text('{"version":1,"providers":[{"id":"claude","enabled":true},{"id":"codex","enabled":true}]}')
    environment = {"HOME": str(root), "CFFIXED_USER_HOME": str(root), "PATH": "/usr/bin:/bin",
        "LANG": "en_US.UTF-8", "TZ": "Asia/Tokyo", "CODEXBAR_CONFIG": str(config)}
    results = {}
    for provider in ["codex", "claude"]:
        for long_context in ([False, True] if provider == "codex" else [False]):
            for speed in (["default", "priority", "fast"] if provider == "codex" else ["standard", "fast"]):
                label = f"{provider}-{long_context}-{speed}"
                case = root / label
                if provider == "codex":
                    write_rows(case / f"codex/sessions/{previous_month}/rollout-{previous_month}-fictional.jsonl",
                        codex_rows("gpt-6.1-sol", speed, 300000 if long_context else 10000))
                else:
                    write_rows(case / "claude/projects/fictional/session.jsonl", claude_rows(speed))
                environment["CODEX_HOME"] = str(case / "codex")
                environment["CLAUDE_CONFIG_DIR"] = str(case / "claude")
                reports = {}
                for period in ["all", "month-to-date"]:
                    for _ in range(12):
                        command = [str(engine), "cost", "--provider", provider, "--period", period,
                            "--format", "json", "--provider-native-only", "--refresh"]
                        result = subprocess.run(command, env=environment, capture_output=True, timeout=60)
                        report = next(row for row in json.loads(result.stdout) if row["provider"] == provider)
                        if report.get("historyCoverageIsEstablished"):
                            break
                    assert report.get("historyCoverageIsEstablished"), label
                    assert not report.get("error"), label
                    assert not report.get("coverage", {}).get("unpriced", 0), label
                    if provider == "codex" and speed in ["priority", "fast"]:
                        for day in report["daily"]:
                            for model in day["modelBreakdowns"]:
                                assert math.isclose(model["priorityCostUSD"], model["cost"], abs_tol=1e-8), label
                                assert model["priorityTokens"] == model["totalTokens"], label
                    reports[period] = report["totals"]
                    assert report["totals"]["totalCost"] > 0, label
                results[label] = reports
                print("PASS read", label, flush=True)
    for provider, long_context in [("codex", False), ("codex", True), ("claude", False)]:
        standard = "default" if provider == "codex" else "standard"
        base = results[f"{provider}-{long_context}-{standard}"]
        expected_standard = (0.6315 if long_context else 0.0115) if provider == "codex" else 0.0596
        assert math.isclose(base["month-to-date"]["totalCost"], expected_standard, abs_tol=1e-8), (provider, long_context, base)
        for speed in (["priority", "fast"] if provider == "codex" else ["fast"]):
            fast = results[f"{provider}-{long_context}-{speed}"]
            for period in ["all", "month-to-date"]:
                assert fast[period]["totalTokens"] == base[period]["totalTokens"], "Speed must not duplicate tokens"
                assert math.isclose(fast[period]["totalCost"], base[period]["totalCost"] * 2, abs_tol=1e-8), (provider, long_context, period)
        assert base["all"]["totalTokens"] == base["month-to-date"]["totalTokens"] * 2
    print("PASS Fast=2x for All and Month, including cache reads, one-hour cache writes, long context, and final-chunk deduplication")
