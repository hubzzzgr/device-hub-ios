"""Run a bounded CI build command and retain its combined output."""

import argparse
import os
from pathlib import Path
import signal
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument("--log", required=True)
parser.add_argument("--label", required=True)
parser.add_argument("--timeout", required=True, type=int)
parser.add_argument("command", nargs=argparse.REMAINDER)
args = parser.parse_args()
command = args.command
if command and command[0] == "--":
    command = command[1:]
if not command:
    parser.error("command is required")
log_path = Path(args.log)
log_path.parent.mkdir(parents=True, exist_ok=True)
with log_path.open("wb") as log:
    process = subprocess.Popen(
        command, stdout=log, stderr=subprocess.STDOUT, start_new_session=True
    )
    try:
        status = process.wait(timeout=args.timeout)
    except (subprocess.TimeoutExpired, KeyboardInterrupt):
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
        status = 124
print(log_path.read_text(errors="replace"))
print(f"{args.label}: exit={status}, log={log_path}")
raise SystemExit(status if status >= 0 else 128 - status)
