#!/usr/bin/env python3
"""WS-8441 end-to-end check — WebSocket over HTTP/2 (RFC 8441 extended CONNECT).

Exists because nothing else in this suite can perform the upgrade. curl,
nghttp and h2load all speak HTTP/2 but none implements RFC 8441, and
TNghttp2Client has no extended CONNECT — so without this the feature ships
compiled-but-unexercised.

Being a different implementation is half its value. The Pascal client encodes
with the codec it decodes with; a symmetric framing bug passes it and fails
every other stack. `h2` is an independent HTTP/2 implementation, the way
grpcurl is for gRPC.

What it asserts, in order:
  1. the server advertises SETTINGS_ENABLE_CONNECT_PROTOCOL
  2. extended CONNECT (:method CONNECT + :protocol websocket) is accepted
     with :status 200 — RFC 8441 §5, there is no 101 in HTTP/2
  3. the server's unprompted "welcome" text frame arrives
  4. a masked client frame round-trips as "echo:<text>"

Usage:  python3 ws8441_check.py [host] [port] [path]
Exit:   0 all checks passed, 1 a check failed, 2 environment problem
Needs:  pip install h2
"""

import socket
import sys
import os
import struct

try:
    import h2.connection
    import h2.config
    import h2.events
    from h2.settings import SettingCodes
except ImportError:
    print("SKIP  python h2 not installed — pip install h2", file=sys.stderr)
    sys.exit(2)

HOST = sys.argv[1] if len(sys.argv) > 1 else "127.0.0.1"
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 9010
PATH = sys.argv[3] if len(sys.argv) > 3 else "/ws"

# EARLY=1 sends the client frame immediately after CONNECT instead of waiting
# for the server's greeting. It separates two very different failures that both
# present as "no echo":
#   EARLY=0 fails, EARLY=1 passes → inbound works, but only for data that
#     arrived BEFORE the handler blocked. The server is not reading the socket
#     while a worker holds the stream.
#   both fail                     → the inbound path never delivers at all.
EARLY = os.environ.get("WS_SEND_EARLY", "0") == "1"

_passed = 0
_failed = 0


def check(ok, desc, detail=""):
    global _passed, _failed
    if ok:
        _passed += 1
        print(f"  PASS  {desc}")
    else:
        _failed += 1
        print(f"  FAIL  {desc}" + (f"  [{detail}]" if detail else ""))


# ── RFC 6455 framing ────────────────────────────────────────────────────────
# Client-to-server frames MUST be masked (§5.3); server-to-client frames MUST
# NOT be. Getting that asymmetry backwards is the classic WebSocket bug: a
# server that accepts unmasked client frames looks fine against a lenient
# client and fails every conforming one.

def ws_text_frame(payload: str) -> bytes:
    data = payload.encode("utf-8")
    mask = os.urandom(4)
    masked = bytes(b ^ mask[i % 4] for i, b in enumerate(data))

    head = bytearray()
    head.append(0x81)                      # FIN=1, opcode=0x1 (text)
    n = len(data)
    if n < 126:
        head.append(0x80 | n)              # MASK=1 + 7-bit length
    elif n < 65536:
        head.append(0x80 | 126)
        head += struct.pack("!H", n)
    else:
        head.append(0x80 | 127)
        head += struct.pack("!Q", n)
    return bytes(head) + mask + masked


def ws_parse_text(buf: bytes):
    """Yield (text, consumed) for each complete unmasked text frame in buf."""
    out, pos = [], 0
    while pos + 2 <= len(buf):
        b0, b1 = buf[pos], buf[pos + 1]
        opcode = b0 & 0x0F
        masked = bool(b1 & 0x80)
        n = b1 & 0x7F
        p = pos + 2
        if n == 126:
            if p + 2 > len(buf):
                break
            n = struct.unpack("!H", buf[p:p + 2])[0]
            p += 2
        elif n == 127:
            if p + 8 > len(buf):
                break
            n = struct.unpack("!Q", buf[p:p + 8])[0]
            p += 8
        if masked:                          # server frames must not be masked
            p += 4
        if p + n > len(buf):
            break
        payload = buf[p:p + n]
        if opcode == 0x1:
            out.append(payload.decode("utf-8", "replace"))
        pos = p + n
    return out, pos


# ── the exchange ────────────────────────────────────────────────────────────

def main():
    print()
    print(f"── WS-8441  {HOST}:{PORT}{PATH}")

    sock = socket.create_connection((HOST, PORT), timeout=10)
    sock.settimeout(5)

    conn = h2.connection.H2Connection(config=h2.config.H2Configuration(client_side=True))
    conn.initiate_connection()
    sock.sendall(conn.data_to_send())

    # Read the server's SETTINGS before deciding anything else — if the flag
    # is absent, the upgrade below would fail for a reason worth naming
    # separately from a broken upgrade.
    enable_connect = None
    deadline_reads = 0
    while enable_connect is None and deadline_reads < 10:
        chunk = sock.recv(65535)
        if not chunk:
            break
        deadline_reads += 1
        for ev in conn.receive_data(chunk):
            if isinstance(ev, h2.events.RemoteSettingsChanged):
                s = ev.changed_settings.get(SettingCodes.ENABLE_CONNECT_PROTOCOL)
                if s is not None:
                    enable_connect = s.new_value
        sock.sendall(conn.data_to_send())

    check(enable_connect == 1,
          "server advertises SETTINGS_ENABLE_CONNECT_PROTOCOL",
          f"got {enable_connect!r} — is EnableWebSocket set before Listen?")
    if enable_connect != 1:
        return 1

    # RFC 8441 §4: extended CONNECT carries :protocol, and unlike the RFC 7540
    # tunnelling form it REQUIRES :scheme and :path.
    stream_id = conn.get_next_available_stream_id()
    conn.send_headers(stream_id, [
        (":method", "CONNECT"),
        (":protocol", "websocket"),
        (":scheme", "http"),
        (":authority", f"{HOST}:{PORT}"),
        (":path", PATH),
        ("sec-websocket-version", "13"),
    ], end_stream=False)
    sock.sendall(conn.data_to_send())

    status, inbound, texts = None, b"", []
    raw_body = b""          # everything received, for diagnosing a non-200
    sent_hello = False

    if EARLY:
        conn.send_data(stream_id, ws_text_frame("hello"), end_stream=False)
        sock.sendall(conn.data_to_send())
        sent_hello = True
        print("    (WS_SEND_EARLY=1 — frame sent before the greeting)")

    try:
        while len(texts) < 2:
            chunk = sock.recv(65535)
            if not chunk:
                break
            for ev in conn.receive_data(chunk):
                if isinstance(ev, h2.events.ResponseReceived):
                    status = dict(ev.headers).get(b":status", b"").decode()
                elif isinstance(ev, h2.events.DataReceived):
                    inbound += ev.data
                    raw_body += ev.data
                    conn.acknowledge_received_data(ev.flow_controlled_length,
                                                   ev.stream_id)
                elif isinstance(ev, (h2.events.StreamEnded, h2.events.StreamReset)):
                    raise RuntimeError("server closed the stream")

            new, consumed = ws_parse_text(inbound)
            if consumed:
                inbound = inbound[consumed:]
            texts += new

            # Only speak once the greeting has arrived, so the echo cannot be
            # confused with it.
            if texts and not sent_hello:
                conn.send_data(stream_id, ws_text_frame("hello"), end_stream=False)
                sent_hello = True

            sock.sendall(conn.data_to_send())
    except (socket.timeout, RuntimeError) as e:
        check(False, "exchange completed", str(e))

    # On a rejection the provider answers {"error":"..."} — printing it turns
    # "why 405?" into a one-line answer instead of a rebuild-and-guess cycle.
    # Which check fired is the whole question: our own bridge reject and
    # Horse's router both produce 405 and mean entirely different things.
    if status != "200" and raw_body:
        print(f"    server said: {raw_body[:400]!r}")

    check(status == "200",
          "extended CONNECT accepted with :status 200 (no 101 in HTTP/2)",
          f"got {status!r}")
    check(len(texts) >= 1 and texts[0] == "welcome",
          "server sent its 'welcome' text frame",
          f"got {texts[:1]!r}")
    check(len(texts) >= 2 and texts[1] == "echo:hello",
          "masked client frame round-tripped as 'echo:hello'",
          f"got {texts[1:2]!r}")

    try:
        conn.close_connection()
        sock.sendall(conn.data_to_send())
    except Exception:
        pass
    sock.close()
    return 1 if _failed else 0


if __name__ == "__main__":
    try:
        rc = main()
    except ConnectionRefusedError:
        print(f"  FAIL  cannot connect to {HOST}:{PORT} — is the server running?")
        rc = 1
    except Exception as e:                      # noqa: BLE001 — report, do not trace
        print(f"  FAIL  {type(e).__name__}: {e}")
        rc = 1
    print(f"  {_passed} passed, {_failed} failed")
    sys.exit(rc)
