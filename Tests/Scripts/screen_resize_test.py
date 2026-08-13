#!/usr/bin/env python3
"""Test how GNU screen responds to pty resizes (TIOCSWINSZ), mimicking the
Shell app: spawn `screen -x` in a pty at 200x24, then shrink to 60x15 and
grow back, capturing whether screen redraws at the new size."""
import fcntl
import os
import select
import signal
import struct
import subprocess
import sys
import termios
import time

NAME = "harness-resize-test"


def esc(b: bytes) -> str:
    out = []
    for c in b:
        if c == 0x1B:
            out.append("\\e")
        elif c == 0x0D:
            out.append("\\r")
        elif c == 0x0A:
            out.append("\\n")
        elif c == 0x09:
            out.append("\\t")
        elif 0x20 <= c < 0x7F:
            out.append(chr(c))
        else:
            out.append(f"\\x{c:02x}")
    return "".join(out)


def set_size(fd, rows, cols):
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))


def drain(fd, pid, seconds):
    """Read whatever the child writes for `seconds`; return bytes."""
    out = bytearray()
    deadline = time.time() + seconds
    while time.time() < deadline:
        r, _, _ = select.select([fd], [], [], 0.1)
        if not r:
            wpid, _ = os.waitpid(pid, os.WNOHANG)
            if wpid == pid:
                return bytes(out)
            continue
        try:
            data = os.read(fd, 65536)
        except OSError:
            return bytes(out)
        if not data:
            return bytes(out)
        out += data
    return bytes(out)


def main() -> int:
    # Clean up any stale session from a previous run.
    subprocess.run(["screen", "-S", NAME, "-X", "quit"],
                   capture_output=True)
    time.sleep(0.3)

    home = os.path.expanduser("~")
    r = subprocess.run(
        ["screen", "-dmS", NAME, "/bin/sh", "-c",
         f"cd '{home}' && exec /bin/zsh -l -i"],
        capture_output=True)
    if r.returncode != 0:
        print("failed to create screen session:", r.stderr.decode())
        return 1
    print("created screen session", NAME)
    time.sleep(1.0)

    # Now attach like the app does: forkpty at 200x24, then resize.
    pid, fd = os.forkpty()
    if pid == 0:
        env = dict(os.environ)
        env["TERM"] = "xterm-256color"
        os.execvp("screen", ["screen", "-x", NAME])
        os._exit(127)

    try:
        set_size(fd, 24, 200)  # app's initial winsize
        time.sleep(0.5)
        print("--- attached, pty 200x24, initial output:")
        initial = drain(fd, pid, 2.0)
        print(esc(initial))

        set_size(fd, 15, 60)  # shrink like a window resize
        print("--- resized pty to 60x15, output after resize:")
        shrunk = drain(fd, pid, 2.5)
        print(esc(shrunk))
        print(f"(shrink produced {len(shrunk)} bytes)")

        set_size(fd, 30, 120)  # grow
        print("--- resized pty to 120x30, output after resize:")
        grown = drain(fd, pid, 2.5)
        print(esc(grown))
        print(f"(grow produced {len(grown)} bytes)")

        # Ask screen its window size via its own mechanism: send nothing,
        # just report totals.
        total = len(initial) + len(shrunk) + len(grown)
        print(f"total bytes: {total}")
    finally:
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        os.waitpid(pid, 0)
        subprocess.run(["screen", "-S", NAME, "-X", "quit"],
                       capture_output=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
