#!/usr/bin/env python3
"""Drive the ESP32-S31 Linux console over a CP2102N UART.

Opening the port resets the board (DTR/RTS drive EN/BOOT), so by default
this waits for boot to finish, then runs one shell command and prints its
output between unique markers.  Use --no-wait-boot when the board is
already at a shell and the port is being reopened without a reset.
"""
import argparse
import re
import sys
import time
import uuid

import serial


def read_until(ser, pattern, timeout, log):
    buf = b""
    deadline = time.monotonic() + timeout
    rx = re.compile(pattern)
    while time.monotonic() < deadline:
        chunk = ser.read(4096)
        if chunk:
            buf += chunk
            log.write(chunk)
            log.flush()
            if rx.search(buf):
                return buf
    raise TimeoutError(f"pattern {pattern!r} not seen within {timeout}s")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", required=True)
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--boot-timeout", type=float, default=120)
    ap.add_argument("--timeout", type=float, default=120)
    ap.add_argument("--no-wait-boot", action="store_true")
    ap.add_argument("--log", help="append the raw console stream here")
    ap.add_argument("command")
    args = ap.parse_args()

    log = open(args.log, "ab") if args.log else open("/dev/null", "wb")
    ser = serial.Serial()
    ser.port = args.port
    ser.baudrate = args.baud
    ser.timeout = 0.2
    ser.dtr = False
    ser.rts = False
    ser.open()

    if not args.no_wait_boot:
        # Busybox init prints nothing reliable on a bare console; wait for
        # the cramfs root mount, then for the line to go quiet.
        read_until(ser, rb"VFS: Mounted root", args.boot_timeout, log)
        quiet_since = time.monotonic()
        while time.monotonic() - quiet_since < 4:
            chunk = ser.read(4096)
            if chunk:
                log.write(chunk)
                quiet_since = time.monotonic()

    tag = uuid.uuid4().hex[:12]
    begin, end = f"__B_{tag}__", f"__E_{tag}__"
    ser.write(b"\n")
    time.sleep(0.5)
    ser.reset_input_buffer()
    # Split the markers so the echoed command line cannot match them.
    line = (f"echo __B_{tag}''__; {{ {args.command} ; }} 2>&1; "
            f"echo __E_{tag}''__rc=$?\n")
    ser.write(line.encode())
    out = read_until(ser, re.escape(end).encode() + rb"rc=\d+",
                     args.timeout, log)
    text = out.decode("utf-8", "replace")
    body = text.split(begin, 1)[-1]
    body, _, tail = body.rpartition(end)
    sys.stdout.write(body.strip("\r\n") + "\n")
    rc = int(re.search(r"rc=(\d+)", tail).group(1))
    sys.stdout.write(f"[rc={rc}]\n")
    ser.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
