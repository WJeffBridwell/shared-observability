#!/usr/bin/env python3
"""
Cost metrics exporter for Prometheus textfile collector.
Scans Claude Code JSONL session files, Twilio API, and Clearing transcripts.
Writes Prometheus exposition format to stdout (pipe to .prom file).

Usage:
  python3 cost-metrics.py > /path/to/textfile_collector/cost_metrics.prom

Run via cron every 5 minutes:
  */5 * * * * python3 /path/to/cost-metrics.py > /path/to/cost_metrics.prom.tmp && mv /path/to/cost_metrics.prom.tmp /path/to/cost_metrics.prom
"""

import json
import os
import glob
import sys
from datetime import datetime, date
from collections import defaultdict

# --- Configuration ---
CLAUDE_PROJECTS_DIR = os.path.expanduser("~/.claude/projects")
CLEARING_TRANSCRIPTS_DIR = os.path.expanduser(
    "~/CascadeProjects/chorus/clearing/transcripts"
)

# Role mapping from project directory path
ROLE_MAP = {
    "-architect/": "silas",
    "-engineer/": "kade",
    "-product-manager/": "wren",
    "-personal-site/": "app",
}


def get_billing_period():
    """Return first day of current month as billing period start."""
    today = date.today()
    return date(today.year, today.month, 1).isoformat()


def map_role(filepath):
    """Map a JSONL file path to a role name."""
    for pattern, role in ROLE_MAP.items():
        if pattern in filepath:
            return role
    return "other"


def scan_claude_sessions():
    """Scan JSONL session files for token usage metrics."""
    billing_start = get_billing_period()
    today = date.today().isoformat()

    daily = defaultdict(lambda: {
        "input": 0, "output": 0, "cache_read": 0, "cache_create": 0,
        "msgs": 0, "sessions": set()
    })
    by_role = defaultdict(lambda: {
        "input": 0, "output": 0, "cache_read": 0, "cache_create": 0, "msgs": 0
    })
    hourly = defaultdict(int)
    total_sessions = set()

    patterns = [
        f"{CLAUDE_PROJECTS_DIR}/-Users-jeffbridwell-CascadeProjects-architect/**/*.jsonl",
        f"{CLAUDE_PROJECTS_DIR}/-Users-jeffbridwell-CascadeProjects-engineer/**/*.jsonl",
        f"{CLAUDE_PROJECTS_DIR}/-Users-jeffbridwell-CascadeProjects-product-manager/**/*.jsonl",
        f"{CLAUDE_PROJECTS_DIR}/-Users-jeffbridwell-CascadeProjects-jeff-bridwell-personal-site/**/*.jsonl",
    ]

    for pattern in patterns:
        for fpath in glob.glob(pattern, recursive=True):
            role = map_role(fpath)
            try:
                with open(fpath) as f:
                    for line in f:
                        try:
                            obj = json.loads(line)
                            ts = obj.get("timestamp", "")
                            if not ts or ts[:10] < billing_start:
                                continue

                            msg = obj.get("message", {})
                            usage = msg.get("usage", {})
                            if not usage:
                                continue

                            day = ts[:10]
                            hour = ts[11:13] if len(ts) > 13 else "00"
                            sid = obj.get("sessionId", "")

                            inp = usage.get("input_tokens", 0)
                            out = usage.get("output_tokens", 0)
                            cr = usage.get("cache_read_input_tokens", 0)
                            cc = usage.get("cache_creation_input_tokens", 0)

                            daily[day]["input"] += inp
                            daily[day]["output"] += out
                            daily[day]["cache_read"] += cr
                            daily[day]["cache_create"] += cc
                            daily[day]["msgs"] += 1
                            daily[day]["sessions"].add(sid)

                            by_role[role]["input"] += inp
                            by_role[role]["output"] += out
                            by_role[role]["cache_read"] += cr
                            by_role[role]["cache_create"] += cc
                            by_role[role]["msgs"] += 1

                            hourly[int(hour)] += 1
                            total_sessions.add(sid)

                        except json.JSONDecodeError:
                            pass
            except Exception:
                pass

    return daily, by_role, hourly, total_sessions, today


def scan_clearing_sessions():
    """Scan Clearing transcript files for session costs."""
    billing_start = get_billing_period()
    total_cost = 0.0
    session_count = 0

    if not os.path.isdir(CLEARING_TRANSCRIPTS_DIR):
        return total_cost, session_count

    for fname in os.listdir(CLEARING_TRANSCRIPTS_DIR):
        if not fname.endswith(".json"):
            continue
        # Filename format: YYYY-MM-DDTHH-MM-SS.json
        if fname[:10] < billing_start:
            continue
        try:
            with open(os.path.join(CLEARING_TRANSCRIPTS_DIR, fname)) as f:
                data = json.load(f)
            session = data.get("session", {})
            cost = session.get("estimatedCost", 0)
            total_cost += cost
            session_count += 1
        except Exception:
            pass

    return total_cost, session_count


def fetch_twilio_costs():
    """Fetch Twilio usage for current month. Returns (sms_cost, sms_count, number_cost, number_count)."""
    account_sid = os.environ.get("TWILIO_ACCOUNT_SID")
    auth_token = os.environ.get("TWILIO_AUTH_TOKEN")

    if not account_sid or not auth_token:
        return 0.0, 0, 0.0, 0

    import urllib.request
    import base64

    today = date.today()
    start = f"{today.year}-{today.month:02d}-01"
    end = today.isoformat()

    creds = base64.b64encode(f"{account_sid}:{auth_token}".encode()).decode()
    headers = {"Authorization": f"Basic {creds}"}

    sms_cost = 0.0
    sms_count = 0
    number_cost = 0.0
    number_count = 0

    try:
        # SMS usage
        url = f"https://api.twilio.com/2010-04-01/Accounts/{account_sid}/Usage/Records.json?Category=sms&StartDate={start}&EndDate={end}"
        req = urllib.request.Request(url, headers=headers)
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = json.loads(resp.read())
        for record in data.get("usage_records", []):
            sms_cost += float(record.get("price", 0))
            sms_count += int(record.get("count", 0))

        # Phone number usage
        url = f"https://api.twilio.com/2010-04-01/Accounts/{account_sid}/Usage/Records.json?Category=phonenumbers&StartDate={start}&EndDate={end}"
        req = urllib.request.Request(url, headers=headers)
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = json.loads(resp.read())
        for record in data.get("usage_records", []):
            number_cost += float(record.get("price", 0))
            number_count += int(record.get("count", 0))

    except Exception:
        pass

    return sms_cost, sms_count, number_cost, number_count


def compute_burn_rate(daily, today):
    """Compute burn rate: usage intensity vs calendar elapsed."""
    today_date = date.fromisoformat(today)
    days_in_month = 28  # Conservative for Feb
    if today_date.month in (1, 3, 5, 7, 8, 10, 12):
        days_in_month = 31
    elif today_date.month in (4, 6, 9, 11):
        days_in_month = 30

    elapsed_pct = (today_date.day / days_in_month) * 100

    # Usage intensity: days with activity / days elapsed
    active_days = len([d for d in daily.values() if d["msgs"] > 0])
    usage_pct = (active_days / max(today_date.day, 1)) * 100

    return elapsed_pct, usage_pct


def write_metrics():
    """Generate Prometheus metrics and write to stdout."""
    daily, by_role, hourly, sessions, today = scan_claude_sessions()
    clearing_cost, clearing_count = scan_clearing_sessions()

    # Twilio — only fetch if env vars present
    sms_cost, sms_count, number_cost, number_count = fetch_twilio_costs()

    elapsed_pct, usage_pct = compute_burn_rate(daily, today)

    total_msgs = sum(d["msgs"] for d in daily.values())
    total_output = sum(d["output"] for d in daily.values())
    total_input = sum(d["input"] for d in daily.values())
    total_cache_read = sum(d["cache_read"] for d in daily.values())

    lines = []
    lines.append("# HELP claude_billing_month_elapsed_pct Percentage of billing month elapsed")
    lines.append("# TYPE claude_billing_month_elapsed_pct gauge")
    lines.append(f"claude_billing_month_elapsed_pct {elapsed_pct:.1f}")

    lines.append("# HELP claude_billing_usage_intensity_pct Percentage of elapsed days with activity")
    lines.append("# TYPE claude_billing_usage_intensity_pct gauge")
    lines.append(f"claude_billing_usage_intensity_pct {usage_pct:.1f}")

    lines.append("# HELP claude_billing_total_messages Total messages this billing period")
    lines.append("# TYPE claude_billing_total_messages gauge")
    lines.append(f"claude_billing_total_messages {total_msgs}")

    lines.append("# HELP claude_billing_total_sessions Total sessions this billing period")
    lines.append("# TYPE claude_billing_total_sessions gauge")
    lines.append(f"claude_billing_total_sessions {len(sessions)}")

    lines.append("# HELP claude_billing_output_tokens Total output tokens this billing period")
    lines.append("# TYPE claude_billing_output_tokens gauge")
    lines.append(f"claude_billing_output_tokens {total_output}")

    lines.append("# HELP claude_billing_input_tokens Total input tokens this billing period")
    lines.append("# TYPE claude_billing_input_tokens gauge")
    lines.append(f"claude_billing_input_tokens {total_input}")

    lines.append("# HELP claude_billing_cache_read_tokens Total cache read tokens this billing period")
    lines.append("# TYPE claude_billing_cache_read_tokens gauge")
    lines.append(f"claude_billing_cache_read_tokens {total_cache_read}")

    # Per-role metrics
    lines.append("# HELP claude_role_messages Messages by role this billing period")
    lines.append("# TYPE claude_role_messages gauge")
    for role, data in by_role.items():
        lines.append(f'claude_role_messages{{role="{role}"}} {data["msgs"]}')

    lines.append("# HELP claude_role_output_tokens Output tokens by role this billing period")
    lines.append("# TYPE claude_role_output_tokens gauge")
    for role, data in by_role.items():
        lines.append(f'claude_role_output_tokens{{role="{role}"}} {data["output"]}')

    # Daily activity (last 7 days)
    lines.append("# HELP claude_daily_messages Messages per day")
    lines.append("# TYPE claude_daily_messages gauge")
    for day in sorted(daily.keys())[-7:]:
        lines.append(f'claude_daily_messages{{date="{day}"}} {daily[day]["msgs"]}')

    lines.append("# HELP claude_daily_output_tokens Output tokens per day")
    lines.append("# TYPE claude_daily_output_tokens gauge")
    for day in sorted(daily.keys())[-7:]:
        lines.append(f'claude_daily_output_tokens{{date="{day}"}} {daily[day]["output"]}')

    lines.append("# HELP claude_daily_sessions Sessions per day")
    lines.append("# TYPE claude_daily_sessions gauge")
    for day in sorted(daily.keys())[-7:]:
        lines.append(f'claude_daily_sessions{{date="{day}"}} {len(daily[day]["sessions"])}')

    # Hourly distribution
    lines.append("# HELP claude_hourly_messages Messages by hour of day")
    lines.append("# TYPE claude_hourly_messages gauge")
    for hour in range(24):
        if hourly[hour] > 0:
            lines.append(f'claude_hourly_messages{{hour="{hour:02d}"}} {hourly[hour]}')

    # Today's metrics
    if today in daily:
        td = daily[today]
        lines.append("# HELP claude_today_messages Messages today")
        lines.append("# TYPE claude_today_messages gauge")
        lines.append(f"claude_today_messages {td['msgs']}")
        lines.append("# HELP claude_today_output_tokens Output tokens today")
        lines.append("# TYPE claude_today_output_tokens gauge")
        lines.append(f"claude_today_output_tokens {td['output']}")
        lines.append("# HELP claude_today_sessions Sessions today")
        lines.append("# TYPE claude_today_sessions gauge")
        lines.append(f"claude_today_sessions {len(td['sessions'])}")

    # Variable costs
    lines.append("# HELP cost_twilio_sms_dollars Twilio SMS cost this billing period")
    lines.append("# TYPE cost_twilio_sms_dollars gauge")
    lines.append(f"cost_twilio_sms_dollars {sms_cost:.4f}")

    lines.append("# HELP cost_twilio_sms_count Twilio SMS count this billing period")
    lines.append("# TYPE cost_twilio_sms_count gauge")
    lines.append(f"cost_twilio_sms_count {sms_count}")

    lines.append("# HELP cost_twilio_numbers_dollars Twilio phone number cost this billing period")
    lines.append("# TYPE cost_twilio_numbers_dollars gauge")
    lines.append(f"cost_twilio_numbers_dollars {number_cost:.4f}")

    lines.append("# HELP cost_twilio_numbers_count Twilio phone number count")
    lines.append("# TYPE cost_twilio_numbers_count gauge")
    lines.append(f"cost_twilio_numbers_count {number_count}")

    lines.append("# HELP cost_clearing_dollars Clearing session cost this billing period")
    lines.append("# TYPE cost_clearing_dollars gauge")
    lines.append(f"cost_clearing_dollars {clearing_cost:.4f}")

    lines.append("# HELP cost_clearing_sessions Clearing session count this billing period")
    lines.append("# TYPE cost_clearing_sessions gauge")
    lines.append(f"cost_clearing_sessions {clearing_count}")

    # Total variable cost
    total_variable = sms_cost + number_cost + clearing_cost
    lines.append("# HELP cost_variable_total_dollars Total variable cost this billing period")
    lines.append("# TYPE cost_variable_total_dollars gauge")
    lines.append(f"cost_variable_total_dollars {total_variable:.4f}")

    # Fixed cost (Claude Code Max plan)
    lines.append("# HELP cost_fixed_claude_dollars Claude Code fixed monthly cost")
    lines.append("# TYPE cost_fixed_claude_dollars gauge")
    lines.append("cost_fixed_claude_dollars 200")

    # Total
    lines.append("# HELP cost_total_dollars Total cost (fixed + variable)")
    lines.append("# TYPE cost_total_dollars gauge")
    lines.append(f"cost_total_dollars {200 + total_variable:.4f}")

    print("\n".join(lines))


if __name__ == "__main__":
    write_metrics()
