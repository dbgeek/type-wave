#!/usr/bin/python3
"""Fault-injection helper: become ready, then never answer inference or cancellation."""

import struct
import sys
import time

DIGEST = bytes.fromhex("1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69")
sys.stdout.buffer.write(struct.pack("<4sHHI", b"TWW1", 2, 1, len(DIGEST)) + DIGEST)
sys.stdout.buffer.flush()
mode = sys.argv[1]
header = sys.stdin.buffer.read(12)
if mode == "stall":
    while sys.stdin.buffer.read(4096):
        time.sleep(0.05)
elif mode == "crash":
    raise SystemExit(17)
elif mode == "malformed":
    sys.stdout.buffer.write(b"malformed")
    sys.stdout.buffer.flush()
elif mode == "inference":
    _, _, _, length = struct.unpack("<4sHHI", header)
    payload = sys.stdin.buffer.read(length)
    request_id = struct.unpack("<Q", payload[:8])[0]
    message = b"inference failed"
    failed = struct.pack("<QHI", request_id, 1, len(message)) + message
    sys.stdout.buffer.write(struct.pack("<4sHHI", b"TWW1", 2, 6, len(failed)) + failed)
    sys.stdout.buffer.flush()
    time.sleep(2)
