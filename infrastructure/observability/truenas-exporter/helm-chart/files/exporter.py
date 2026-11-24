#!/usr/bin/env python3
"""Prometheus exporter for TrueNAS pool usage and the TrueNAS alert list.

Uses the TrueNAS JSON-RPC 2.0 API over a websocket (wss://<host>/api/current),
which honours the roles of a read-only user (POOL_READ, ALERT_LIST_READ). The
REST API (/api/v2.0) only answers full admins on TrueNAS 25.10.

Python standard library only: no packages to install. Each scrape of
/metrics opens one connection, logs in with the API key, runs pool.query and
alert.list, and closes the connection.

Environment:
  TRUENAS_HOST         host name or address of the NAS (required)
  TRUENAS_API_KEY_FILE file with the API key (default /etc/truenas/api-key)
  TRUENAS_API_KEY      the API key itself (for a local test, wins over the file)
  TRUENAS_VERIFY_TLS   "true" to check the NAS certificate (default false)
  LISTEN_PORT          port of the metrics server (default 9814)

Local test without a server: TRUENAS_HOST=... TRUENAS_API_KEY=... exporter.py --once
"""

import base64
import http.server
import json
import os
import socket
import ssl
import struct
import sys
import time

TIMEOUT = 20


class WebSocket:
    """Minimal websocket client (RFC 6455): text frames, ping, close."""

    def __init__(self, host, path, verify_tls):
        ctx = ssl.create_default_context()
        if not verify_tls:
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE
        raw = socket.create_connection((host, 443), timeout=TIMEOUT)
        self.sock = ctx.wrap_socket(raw, server_hostname=host)
        key = base64.b64encode(os.urandom(16)).decode()
        self.sock.sendall(
            (
                f"GET {path} HTTP/1.1\r\n"
                f"Host: {host}\r\n"
                "Upgrade: websocket\r\n"
                "Connection: Upgrade\r\n"
                f"Sec-WebSocket-Key: {key}\r\n"
                "Sec-WebSocket-Version: 13\r\n\r\n"
            ).encode()
        )
        head = b""
        while b"\r\n\r\n" not in head:
            chunk = self.sock.recv(1)
            if not chunk:
                raise ConnectionError("connection closed during websocket handshake")
            head += chunk
        status = head.split(b"\r\n", 1)[0].decode(errors="replace")
        if " 101 " not in status + " ":
            raise ConnectionError(f"websocket handshake failed: {status}")

    def _recv_exact(self, n):
        buf = b""
        while len(buf) < n:
            chunk = self.sock.recv(n - len(buf))
            if not chunk:
                raise ConnectionError("connection closed")
            buf += chunk
        return buf

    def _send_frame(self, opcode, payload):
        header = bytes([0x80 | opcode])
        n = len(payload)
        if n < 126:
            header += bytes([0x80 | n])
        elif n < 1 << 16:
            header += bytes([0x80 | 126]) + struct.pack("!H", n)
        else:
            header += bytes([0x80 | 127]) + struct.pack("!Q", n)
        mask = os.urandom(4)
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        self.sock.sendall(header + mask + masked)

    def send(self, text):
        self._send_frame(0x1, text.encode())

    def recv(self):
        message = b""
        while True:
            b1, b2 = self._recv_exact(2)
            fin, opcode = b1 & 0x80, b1 & 0x0F
            n = b2 & 0x7F
            if n == 126:
                n = struct.unpack("!H", self._recv_exact(2))[0]
            elif n == 127:
                n = struct.unpack("!Q", self._recv_exact(8))[0]
            mask = self._recv_exact(4) if b2 & 0x80 else None
            payload = self._recv_exact(n)
            if mask:
                payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
            if opcode == 0x8:
                raise ConnectionError("server closed the websocket")
            if opcode == 0x9:
                self._send_frame(0xA, payload)
                continue
            if opcode == 0xA:
                continue
            message += payload
            if fin:
                return message.decode()

    def close(self):
        try:
            self._send_frame(0x8, b"")
        except OSError:
            pass
        self.sock.close()


class TrueNAS:
    def __init__(self, host, verify_tls):
        self.ws = WebSocket(host, "/api/current", verify_tls)
        self.next_id = 0

    def call(self, method, params=None):
        self.next_id += 1
        call_id = self.next_id
        self.ws.send(
            json.dumps({"jsonrpc": "2.0", "id": call_id, "method": method, "params": params or []})
        )
        while True:
            reply = json.loads(self.ws.recv())
            if reply.get("id") != call_id:
                continue  # an event or notification, not our answer
            if "error" in reply:
                raise RuntimeError(f"{method}: {reply['error']}")
            return reply["result"]

    def close(self):
        self.ws.close()


def label_value(value):
    return str(value).replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def labels(**kv):
    return "{" + ",".join(f'{k}="{label_value(v)}"' for k, v in kv.items()) + "}"


def read_api_key():
    if os.environ.get("TRUENAS_API_KEY"):
        return os.environ["TRUENAS_API_KEY"].strip()
    with open(os.environ.get("TRUENAS_API_KEY_FILE", "/etc/truenas/api-key")) as f:
        return f.read().strip()


def collect():
    host = os.environ["TRUENAS_HOST"]
    verify_tls = os.environ.get("TRUENAS_VERIFY_TLS", "false").lower() == "true"
    lines = []
    up = 0
    start = time.monotonic()
    try:
        api = TrueNAS(host, verify_tls)
        try:
            if not api.call("auth.login_with_api_key", [read_api_key()]):
                raise PermissionError("TrueNAS refused the API key")
            pools = api.call(
                "pool.query",
                [[], {"select": ["name", "size", "allocated", "free", "healthy"]}],
            )
            alerts = api.call("alert.list")
        finally:
            api.close()

        lines += [
            "# HELP truenas_pool_size_bytes Raw size of the pool (zpool list).",
            "# TYPE truenas_pool_size_bytes gauge",
            "# HELP truenas_pool_allocated_bytes Raw space in use in the pool (zpool list).",
            "# TYPE truenas_pool_allocated_bytes gauge",
            "# HELP truenas_pool_free_bytes Raw free space in the pool (zpool list).",
            "# TYPE truenas_pool_free_bytes gauge",
            "# HELP truenas_pool_healthy 1 when TrueNAS reports the pool as healthy.",
            "# TYPE truenas_pool_healthy gauge",
        ]
        for pool in pools:
            lbl = labels(pool=pool["name"])
            for field in ("size", "allocated", "free"):
                if pool.get(field) is not None:
                    lines.append(f"truenas_pool_{field}_bytes{lbl} {pool[field]}")
            lines.append(f"truenas_pool_healthy{lbl} {1 if pool.get('healthy') else 0}")

        lines += [
            "# HELP truenas_alert_active One series per TrueNAS alert that is not dismissed.",
            "# TYPE truenas_alert_active gauge",
        ]
        for alert in alerts:
            if alert.get("dismissed"):
                continue
            lbl = labels(
                uuid=alert.get("uuid", ""),
                klass=alert.get("klass", ""),
                level=alert.get("level", ""),
                text=alert.get("formatted") or "",
            )
            lines.append(f"truenas_alert_active{lbl} 1")
        up = 1
    except Exception as e:  # report every failure as truenas_up 0
        print(f"scrape failed: {type(e).__name__}: {e}", file=sys.stderr, flush=True)

    lines += [
        "# HELP truenas_up 1 when the last scrape of the TrueNAS API worked.",
        "# TYPE truenas_up gauge",
        f"truenas_up {up}",
        "# HELP truenas_scrape_duration_seconds Time of the last scrape of the TrueNAS API.",
        "# TYPE truenas_scrape_duration_seconds gauge",
        f"truenas_scrape_duration_seconds {time.monotonic() - start:.3f}",
    ]
    return "\n".join(lines) + "\n"


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/metrics":
            body, ctype = collect().encode(), "text/plain; version=0.0.4"
        elif self.path == "/healthz":
            body, ctype = b"ok\n", "text/plain"
        else:
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass  # no log line per scrape


if __name__ == "__main__":
    if "--once" in sys.argv:
        sys.stdout.write(collect())
        sys.exit(0)
    port = int(os.environ.get("LISTEN_PORT", "9814"))
    print(f"listening on :{port}", flush=True)
    http.server.ThreadingHTTPServer(("", port), Handler).serve_forever()
