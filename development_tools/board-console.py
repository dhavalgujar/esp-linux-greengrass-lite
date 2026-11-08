#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Espressif Systems (Shanghai) CO LTD
# SPDX-License-Identifier: Apache-2.0
"""Run shell commands on an ESP32-S31 board through its serial console.

  board-console.py serve --port PORT --mac MAC --socket SOCK [--log FILE]
  board-console.py run --socket SOCK [--prelude TEXT] [--timeout S] -- WORD...
  board-console.py reset --socket SOCK
  board-console.py stop --socket SOCK
  board-console.py once --port PORT --mac MAC [--log FILE] -- WORD...|-

The Function-CoreBoard's CP2102N resets the board whenever its port is
opened, so one server holds the port for a whole session and types each
command into the console shell; clients reach it through a Unix socket.
Commands cost the board a shell and a sh(1), not an SSH server, a key
exchange and a network connection, and a busy board is slow rather than
unreachable.

`serve` checks the chip's MAC with esptool (ESP_ESPTOOL), then opens the
port, which resets the board, and follows the console from then on. Nothing
is typed between a reset and U-Boot's "Starting kernel": any key stops
U-Boot's autoboot (if one does, the server types "boot"). Once Linux is up
it logs in as root on a login prompt and checks that a shell answers. The
whole console stream goes to --log.

`run` joins its words with spaces, as ssh(1) does, and runs them with
sh(1) on the board, stdin from /dev/null; the script travels base64-encoded,
so the shell's line editing sees nothing but letters and digits. A prelude
is uploaded once per boot and sourced before each command. Exit status is
the command's, or 255 if it could not be run or did not finish: no shell
within --ready-timeout, a reset during the command, or --timeout (after
which the command is interrupted). Kernel and systemd status lines that
land on the console during a command are removed from its output.

`reset` resets the board through RTS (the chip's EN), as esptool does.

`once` opens the port (resetting the board), runs one script as `run`
does (from standard input with "-"), and closes the port.
"""
import argparse
import base64
import hashlib
import json
import os
import re
import socket
import socketserver
import subprocess
import sys
import threading
import time
import uuid

BOOT = b"ESP-ROM:"
KERNEL = b"Starting kernel"
GOING_DOWN = (b"reboot: Restarting system", b"reboot: Power down",
              b"reboot: System halted")
PANIC = b"Kernel panic - not syncing"
KERNEL_LINE = re.compile(rb"\[ *\d+\.\d{6}\] ")
# systemd's status lines, while it boots or shuts down, once colors are off
STATUS_LINE = re.compile(rb"^(\[ *(OK|FAILED|DEPEND|TIME|\*+) *\] | {9}"
                         rb"(Starting|Stopping|Mounting|Unmounting|"
                         rb"Activating|Deactivating|Reloading) )")
COLOR = re.compile(rb"\x1b\[[0-9;]*m")
BUF_MAX = 8 << 20


class BoardReset(Exception):
    pass


class NotReady(Exception):
    pass


class Console:
    def __init__(self, ser, log):
        self.ser = ser
        self.log = log
        self.cv = threading.Condition()
        self.op = threading.Lock()
        self.buf = bytearray()
        self.base = 0          # stream offset of buf[0]
        self.line = bytearray()
        self.boots = 0         # resets seen on the console
        self.can_type = False  # Linux is past U-Boot
        self.ready = False     # a shell answered since the last reset
        self.panic = None      # the kernel's panic line, until a reset
        self.boot_at = self.rx_at = time.monotonic()
        self.preludes = set()  # uploaded since the last reset
        threading.Thread(target=self._reader, daemon=True).start()

    # Reading: everything goes to the log; whole lines update the state.

    def _reader(self):
        while True:
            data = self.ser.read(4096)
            if not data:
                continue
            self.rx_at = time.monotonic()
            self.log.write(data)
            self.log.flush()
            # The console pads its output with NUL bytes, also inside the
            # shell's echo of what is typed.
            data = data.replace(b"\0", b"")
            with self.cv:
                self.buf += data
                if len(self.buf) > BUF_MAX:
                    drop = len(self.buf) - BUF_MAX // 2
                    del self.buf[:drop]
                    self.base += drop
                parts = data.split(b"\n")
                for part in parts[:-1]:
                    self.line += part
                    self._on_line(bytes(self.line))
                    self.line.clear()
                self.line += parts[-1]
                del self.line[:-4096]
                self.cv.notify_all()

    def _on_line(self, line):
        if BOOT in line:
            self.boot_at = time.monotonic()
            self.boots += 1
            self.can_type = self.ready = False
            self.panic = None
            self.preludes.clear()
        elif PANIC in line:
            self.can_type = self.ready = False
            self.panic = line.decode(errors="replace").strip()
        elif KERNEL in line:
            self.can_type = True
        elif any(m in line for m in GOING_DOWN):
            self.can_type = self.ready = False

    def note(self, text):
        self.log.write(f"\n### board-console: {text}\n".encode())
        self.log.flush()

    def end(self):
        with self.cv:
            return self.base + len(self.buf)

    def tail(self, start):
        with self.cv:
            return bytes(self.buf[max(start - self.base, 0):])

    def wait_for(self, pattern, start, timeout, boots=None):
        """Stream offset just past PATTERN (bytes or regex) after START."""
        rx = pattern if hasattr(pattern, "search") else \
            re.compile(re.escape(pattern))
        deadline = time.monotonic() + timeout
        with self.cv:
            while True:
                if boots is not None and self.boots != boots:
                    raise BoardReset()
                m = rx.search(self.buf, max(start - self.base, 0))
                if m:
                    return self.base + m.end(), m
                left = deadline - time.monotonic()
                if left <= 0:
                    raise TimeoutError()
                self.cv.wait(min(left, 1))

    def quiet(self, seconds, timeout):
        """Waits until nothing arrived for SECONDS (at most TIMEOUT)."""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            n = self.end()
            time.sleep(seconds)
            if self.end() == n:
                return

    # Typing: only once Linux runs, never into U-Boot.

    def write(self, data, boots=None):
        with self.cv:
            if not self.can_type or (boots is not None and
                                     self.boots != boots):
                raise BoardReset()
        self.ser.write(data)
        self.ser.flush()

    def ensure_ready(self, timeout):
        deadline = time.monotonic() + timeout
        while True:
            with self.cv:
                if self.ready:
                    return
                if self.panic:
                    raise NotReady(self.panic)
                can_type, boots = self.can_type, self.boots
            if time.monotonic() > deadline:
                raise NotReady("no shell on the console")
            if not can_type:
                self._resume_uboot()
                self._unstall_boot()
                time.sleep(1)
                continue
            try:
                start = self.end()
                self.write(b"\r", boots)
                self.quiet(1, 5)
                text = self.tail(start).rstrip()
                if text.endswith(b"login:"):
                    self.write(b"root\r", boots)
                    self.quiet(1, 15)
                    if self.tail(start).rstrip().endswith(b"Password:"):
                        self.write(b"\r", boots)
                        self.quiet(1, 15)
                tag = uuid.uuid4().hex[:8]
                start = self.end()
                self.write(f"printf '%s%s\\n' __BC_{tag} _UP\r".encode(),
                           boots)
                self.wait_for(f"__BC_{tag}_UP".encode(), start, 15, boots)
                with self.cv:
                    if self.boots == boots:
                        self.ready = True
            except (BoardReset, TimeoutError):
                pass

    def _resume_uboot(self):
        # A key that reached U-Boot during its countdown leaves it at its
        # prompt; continue the boot.
        with self.cv:
            text = bytes(self.buf[-4096:])
        boot = text.rfind(BOOT)
        if boot < 0 or KERNEL in text[boot:]:
            return
        if b"autoboot" in text[boot:] and text.rstrip().endswith(b"=>"):
            n = self.end()
            time.sleep(2)
            if self.end() == n:
                self.note("U-Boot stopped its autoboot; typing boot")
                self.ser.write(b"boot\r")
                self.ser.flush()

    def _unstall_boot(self):
        # A boot that went quiet before the kernel (seen once: U-Boot SPL
        # hung after switching the flash to QIO) is reset.
        now = time.monotonic()
        with self.cv:
            stalled = (self.boots > 0 and not self.can_type and
                       not self.panic and now - self.boot_at > 90 and
                       now - self.rx_at > 30)
            text = bytes(self.buf[-200:])
        if stalled and not text.rstrip().endswith(b"=>"):
            last = text.rstrip().rsplit(b"\n", 1)[-1].strip()
            self.note(f"the boot stalled after "
                      f"{last.decode(errors='replace')!r}; resetting")
            self.reset()

    # Scripts reach the board through this helper, uploaded once per boot:
    # it reads them from the terminal with its echo off. The shell's line
    # editor echoes each typed character with a write of its own, about
    # 200 bytes/s here, so only "sh HELPER TAG" goes through it.
    HELPER = "/tmp/.bc-r"
    HELPER_SH = r"""t=$1 f=/tmp/.bc-$1
stty -echo
printf '%s%s\n' __BC_$t _RDY
base64 -d >"${2:-$f}"
stty echo
if [ -n "$2" ]; then printf '%s%s %s\n' __BC_$t _R 0; exit; fi
printf '%s%s\n' __BC_$t _B
sh "$f" </dev/null 2>"$f.e"
r=$?
printf '\n%s%s\n' __BC_$t _E
cat "$f.e"
printf '\n%s%s %s\n' __BC_$t _R "$r"
rm -f "$f" "$f.e"
"""
    # Most of what the terminal's buffers hold without flow control.
    SEND_MAX = 32 << 10

    def send(self, start_line, ready, text, boots, timeout):
        """Types START_LINE, waits for READY, then sends TEXT base64-encoded
        up to an end of file (Ctrl-D)."""
        data = base64.encodebytes(text.encode())
        if len(data) > self.SEND_MAX:
            raise ValueError("script too long for the console")
        start = self.end()
        self.write(start_line.encode() + b"\r", boots)
        self.wait_for(ready.encode(), start, timeout, boots)
        self.write(data + b"\x04", boots)

    def helper(self, boots):
        if self.HELPER in self.preludes:
            return
        self.send(f"stty -echo; printf '%s%s\\n' __BC_ _HLP; "
                  f"base64 -d >{self.HELPER}; stty echo",
                  "__BC__HLP", self.HELPER_SH, boots, 60)
        self.preludes.add(self.HELPER)

    def store(self, path, text, boots):
        tag = uuid.uuid4().hex[:12]
        start = self.end()
        self.send(f"sh {self.HELPER} {tag} {path}", f"__BC_{tag}_RDY", text,
                  boots, 120)
        self.wait_for(f"__BC_{tag}_R 0".encode(), start, 120, boots)

    def run(self, script, prelude, timeout, ready_timeout):
        with self.op:
            try:
                self.ensure_ready(ready_timeout)
            except NotReady as e:
                return 255, b"", f"board-console: {e}\n".encode()
            boots = self.boots
            tag = uuid.uuid4().hex[:12]
            try:
                self.helper(boots)
                if prelude:
                    p = "/tmp/.bc-" + \
                        hashlib.sha256(prelude.encode()).hexdigest()[:12]
                    if p not in self.preludes:
                        self.store(p, prelude, boots)
                        self.preludes.add(p)
                    script = f". {p}\n{script}"
                start = self.end()
                self.send(f"sh {self.HELPER} {tag}", f"__BC_{tag}_RDY",
                          script + "\n", boots, timeout)
                b, _ = self.wait_for(
                    re.compile(f"__BC_{tag}_B\r?\n".encode()), start,
                    timeout, boots)
                e, m = self.wait_for(
                    re.compile(f"__BC_{tag}_R (\\d+)\r?\n".encode()), b,
                    timeout, boots)
            except ValueError as err:
                return 255, b"", f"board-console: {err}\n".encode()
            except BoardReset:
                return 255, b"", b"board-console: the board reset\n"
            except TimeoutError:
                self.note(f"command {tag} timed out; interrupting it")
                with self.cv:
                    self.ready = False
                try:
                    self.write(b"\x03", boots)
                except BoardReset:
                    pass
                return 255, b"", b"board-console: the command timed out\n"
            with self.cv:
                text = bytes(self.buf[b - self.base:e - self.base])
            text = clean(text)
            out, _, rest = text.partition(f"\n__BC_{tag}_E\n".encode())
            err = rest.rpartition(f"\n__BC_{tag}_R ".encode())[0]
            return int(m.group(1)), out, err

    # Not serialized with commands: a command in progress fails (the board
    # reset), and a wait for a shell goes on with the new boot.
    def reset(self):
        with self.cv:
            boots = self.boots
            self.can_type = self.ready = False
        self.note("reset through RTS")
        self.ser.rts = True
        time.sleep(0.1)
        self.ser.rts = False
        with self.cv:
            deadline = time.monotonic() + 10
            while self.boots == boots and time.monotonic() < deadline:
                self.cv.wait(1)
            return self.boots != boots


def clean(text):
    """Drops carriage returns, and kernel and systemd status lines (a kernel
    line may start mid-line: what preceded it continues after it)."""
    lines, carry = [], b""
    for line in text.replace(b"\r", b"").split(b"\n"):
        m = KERNEL_LINE.search(line)
        if m:
            carry += line[:m.start()]
            continue
        if STATUS_LINE.match(COLOR.sub(b"", line)):
            continue
        lines.append(carry + line)
        carry = b""
    if carry:
        lines.append(carry)
    return b"\n".join(lines)


def open_console(args):
    esptool = os.environ.get("ESP_ESPTOOL", "esptool")
    out = subprocess.run([esptool, "--port", args.port, "read-mac"],
                         capture_output=True, text=True).stdout
    mac = re.search(r"^MAC: *(\S+)", out, re.M)
    if not mac or mac.group(1).lower() != args.mac.lower():
        sys.exit(f"chip on {args.port} reports MAC "
                 f"'{mac.group(1) if mac else ''}', expected '{args.mac}'; "
                 "refusing")

    import serial
    ser = serial.Serial()
    ser.port, ser.baudrate, ser.timeout = args.port, 115200, 0.2
    ser.dtr = ser.rts = False
    ser.open()
    log = open(args.log, "ab") if args.log else open(os.devnull, "wb")
    con = Console(ser, log)
    # Opening the port resets the board; if no boot shows up, assume a
    # running system.
    time.sleep(3)
    with con.cv:
        if con.boots == 0:
            con.can_type = True
    if con.boots == 0:
        con.note("no reset seen on opening the port")
    return ser, con


def serve(args):
    ser, con = open_console(args)
    stop = threading.Event()

    class Handler(socketserver.StreamRequestHandler):
        def handle(self):
            req = json.loads(self.rfile.readline())
            if req["op"] == "run":
                rc, o, e = con.run(req["script"], req.get("prelude"),
                                   req["timeout"], req["ready_timeout"])
                resp = {"rc": rc, "out": base64.b64encode(o).decode(),
                        "err": base64.b64encode(e).decode()}
            elif req["op"] == "reset":
                resp = {"rc": 0 if con.reset() else 255}
            elif req["op"] == "stop":
                resp = {"rc": 0}
                stop.set()
            else:
                resp = {"rc": 2}
            self.wfile.write(json.dumps(resp).encode() + b"\n")

    if os.path.exists(args.socket):
        os.unlink(args.socket)
    srv = socketserver.ThreadingUnixStreamServer(args.socket, Handler)
    srv.daemon_threads = True
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    stop.wait()
    srv.shutdown()
    os.unlink(args.socket)
    ser.close()


def call(sock_path, req):
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
            s.connect(sock_path)
            s.sendall(json.dumps(req).encode() + b"\n")
            data = b""
            while not data.endswith(b"\n"):
                chunk = s.recv(65536)
                if not chunk:
                    break
                data += chunk
        return json.loads(data)
    except (OSError, ValueError) as e:
        sys.stderr.write(f"board-console: {e}\n")
        return {"rc": 255}


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("serve")
    p.add_argument("--port", required=True)
    p.add_argument("--mac", required=True)
    p.add_argument("--socket", required=True)
    p.add_argument("--log")
    p = sub.add_parser("run")
    p.add_argument("--socket", required=True)
    p.add_argument("--prelude")
    p.add_argument("--timeout", type=float, default=1200)
    p.add_argument("--ready-timeout", type=float, default=900)
    p.add_argument("words", nargs="+")
    for name in ("reset", "stop"):
        sub.add_parser(name).add_argument("--socket", required=True)
    p = sub.add_parser("once")
    p.add_argument("--port", required=True)
    p.add_argument("--mac", required=True)
    p.add_argument("--log")
    p.add_argument("--timeout", type=float, default=1200)
    p.add_argument("--ready-timeout", type=float, default=900)
    p.add_argument("words", nargs="+")
    args = ap.parse_args()

    if args.cmd == "serve":
        serve(args)
        return 0
    if args.cmd == "once":
        script = sys.stdin.read() if args.words == ["-"] else \
            " ".join(args.words)
        ser, con = open_console(args)
        rc, out, err = con.run(script, None, args.timeout,
                               args.ready_timeout)
        sys.stdout.buffer.write(out)
        sys.stderr.buffer.write(err)
        ser.close()
        return rc
    if args.cmd == "run":
        resp = call(args.socket, {
            "op": "run", "script": " ".join(args.words),
            "prelude": args.prelude, "timeout": args.timeout,
            "ready_timeout": args.ready_timeout})
        sys.stdout.buffer.write(base64.b64decode(resp.get("out", "")))
        sys.stderr.buffer.write(base64.b64decode(resp.get("err", "")))
        return resp["rc"]
    return call(args.socket, {"op": args.cmd})["rc"]


if __name__ == "__main__":
    sys.exit(main())
