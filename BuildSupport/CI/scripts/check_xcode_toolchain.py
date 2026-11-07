"""Validate the actual Xcode and iPhoneOS SDK selected on a CI runner."""

import argparse
import re
import subprocess


def version(text):
    match = re.search(r"(\d+)\.(\d+)", text)
    if not match:
        raise SystemExit(f"Cannot determine version: {text!r}")
    return tuple(map(int, match.groups()))


parser = argparse.ArgumentParser()
parser.add_argument("--minimum-xcode", required=True)
parser.add_argument("--minimum-ios-sdk", required=True)
args = parser.parse_args()
for command, minimum in (
    (["xcodebuild", "-version"], args.minimum_xcode),
    (["xcrun", "--sdk", "iphoneos", "--show-sdk-version"], args.minimum_ios_sdk),
):
    output = subprocess.check_output(command, text=True)
    print(output, end="")
    if version(output) < version(minimum):
        raise SystemExit(f"Required version: {minimum} or later")
