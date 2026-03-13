#!/usr/bin/env python3
"""
alert-notifier.py — macOS native notification receiver for Alertmanager webhooks.

Listens on HTTP port 9095 for Alertmanager webhook POSTs.
Fires macOS banner notifications via terminal-notifier — no TCC prompts.
Multiple alerts in a batch are grouped into a single notification.

Also logs every alert to chorus-log.

Card #202. Silas owns.
"""

import json
import os
import shutil
import subprocess
import sys
from datetime import datetime
from http.server import HTTPServer, BaseHTTPRequestHandler

PORT = int(os.environ.get("ALERT_NOTIFIER_PORT", "9095"))
CHORUS_LOG = os.path.expanduser("~/CascadeProjects/messages/scripts/chorus-log.sh")
GRAFANA_ALERTS_URL = "http://localhost:3100/d/alerts-overview"
TERMINAL_NOTIFIER = shutil.which("terminal-notifier")


def macos_notify(title: str, message: str, severity: str = "warning", silent: bool = False):
    """Fire a macOS banner notification. Never modal — never steals focus."""
    sound = "Ping" if severity == "critical" else "Sosumi"
    if TERMINAL_NOTIFIER:
        try:
            args = [
                TERMINAL_NOTIFIER,
                "-title", title,
                "-message", message,
                "-group", "chorus-alert",
            ]
            if not silent:
                args.extend(["-sound", sound])
            subprocess.run(args, timeout=10)
        except Exception as e:
            print(f"[alert-notifier] terminal-notifier failed: {e}", file=sys.stderr)
    else:
        # Fallback to osascript if terminal-notifier not installed
        script = (
            f'display notification "{esc(message)}" '
            f'with title "{esc(title)}" '
            f'sound name "{sound}"'
        )
        try:
            subprocess.run(["osascript", "-e", script], timeout=10)
        except Exception as e:
            print(f"[alert-notifier] osascript failed: {e}", file=sys.stderr)


def esc(s: str) -> str:
    """Escape double quotes for AppleScript strings."""
    return s.replace('"', '\\"').replace('\n', ' ')


def chorus_log(event: str, role: str = "system", **kwargs):
    """Log to chorus-log if available. Args become key=value pairs."""
    if os.path.isfile(CHORUS_LOG):
        try:
            args = [CHORUS_LOG, event, role]
            for k, v in kwargs.items():
                args.append(f"{k}={v}")
            subprocess.run(args, timeout=5, capture_output=True)
        except Exception:
            pass


class AlertHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        content_length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_length)

        try:
            payload = json.loads(body)
        except json.JSONDecodeError:
            self.send_response(400)
            self.end_headers()
            self.wfile.write(b"invalid json")
            return

        # --- Harvest completion/failure notifications (#1346) ---
        if self.path == "/harvest":
            domain = payload.get("domain", "unknown")
            result = payload.get("result", "unknown")  # "completed" or "failed"
            items = payload.get("items", 0)
            duration = payload.get("duration", "")
            error = payload.get("error", "")

            if result == "failed":
                title = f"🔴 Harvest failed: {domain}"
                body_text = error[:120] if error else "No error details"
                macos_notify(title, body_text, "critical")
            else:
                title = f"✅ Harvest done: {domain}"
                body_text = f"{items} items in {duration}" if duration else f"{items} items"
                macos_notify(title, body_text, "warning", silent=True)
            chorus_log("harvest.notify.sent", "system",
                       domain=domain, result=result, items=str(items))
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"ok")
            return

        # --- Brief delivery notifications (#616) ---
        if self.path == "/brief":
            sender = payload.get("from", "unknown")
            recipient = payload.get("to", "unknown")
            artifact = payload.get("artifact", "brief")
            # Strip date prefix and .md for cleaner display
            display = artifact
            if display.endswith(".md"):
                display = display[:-3]
            # Remove leading date if present (YYYY-MM-DD-)
            if len(display) > 11 and display[10] == "-":
                display = display[11:]
            title = f"Brief for {recipient.capitalize()}"
            body_text = f"From {sender.capitalize()}: {display}"
            macos_notify(title, body_text, "warning")
            chorus_log("brief.notify.sent", "system",
                       **{"from": sender, "to": recipient, "artifact": artifact})
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"ok")
            return

        alerts = payload.get("alerts", [])
        firing = [a for a in alerts if a.get("status") == "firing"]
        resolved = [a for a in alerts if a.get("status") == "resolved"]

        # Batch firing alerts into one notification
        if firing:
            has_critical = any(
                a.get("labels", {}).get("severity") == "critical"
                for a in firing
            )
            severity = "critical" if has_critical else "warning"
            icon = "🔴" if has_critical else "🟡"

            # Build summary lines
            names = []
            for alert in firing:
                labels = alert.get("labels", {})
                annotations = alert.get("annotations", {})
                name = labels.get("alertname", "Unknown")
                summary = annotations.get("summary", name)
                names.append(name)
                chorus_log("ops.alert.fired", "system", alertname=name, severity=labels.get('severity', 'warning'), summary=summary)

            if len(firing) == 1:
                title = f"{icon} {names[0]}"
                body = firing[0].get("annotations", {}).get("summary", names[0])
            else:
                title = f"{icon} {len(firing)} alerts firing"
                # Dedupe alert names for compact display
                unique = list(dict.fromkeys(names))
                body = ", ".join(unique[:4])
                if len(unique) > 4:
                    body += f" +{len(unique) - 4} more"

            body += f"\n{GRAFANA_ALERTS_URL}"
            macos_notify(title, body, severity)

        # Log resolved (no notification — just chorus-log)
        for alert in resolved:
            labels = alert.get("labels", {})
            name = labels.get("alertname", "Unknown")
            chorus_log("ops.alert.resolved", "system", alertname=name)

        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"ok")

    def do_GET(self):
        """Health check endpoint."""
        if self.path == "/health":
            self.send_response(200)
            self.end_headers()
            self.wfile.write(json.dumps({
                "status": "ok",
                "uptime_since": START_TIME,
                "port": PORT,
            }).encode())
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, format, *args):
        """Suppress default request logging to stderr."""
        pass


if __name__ == "__main__":
    START_TIME = datetime.now().isoformat()
    print(f"[alert-notifier] listening on :{PORT}", file=sys.stderr)
    server = HTTPServer(("0.0.0.0", PORT), AlertHandler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n[alert-notifier] stopped", file=sys.stderr)
        server.server_close()
