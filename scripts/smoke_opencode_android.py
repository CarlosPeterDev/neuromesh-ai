"""Exercise the Agent Hub in an installed Android package against OpenCode."""

import re
import subprocess
import sys
import time
from xml.etree import ElementTree


def adb(*arguments):
    return subprocess.check_output(("adb", *arguments), text=True, timeout=20)


def screen():
    path = "/sdcard/neuromesh-ci-window.xml"
    adb("shell", "uiautomator", "dump", path)
    return ElementTree.fromstring(adb("shell", "cat", path))


def find(root, label):
    for node in root.iter("node"):
        if label in (node.get("text"), node.get("content-desc")):
            return node
    return None


def tap(node):
    left, top, right, bottom = map(int, re.findall(r"\d+", node.get("bounds")))
    adb("shell", "input", "tap", str((left + right) // 2), str((top + bottom) // 2))


def scroll():
    bounds = adb("shell", "wm", "size").strip().split()[-1]
    width, height = map(int, bounds.split("x"))
    adb("shell", "input", "swipe", str(width // 2), str(3 * height // 4),
        str(width // 2), str(height // 3), "300")


def wait_for(label, *, can_scroll=False):
    deadline = time.monotonic() + 45
    while time.monotonic() < deadline:
        try:
            node = find(screen(), label)
            if node is not None:
                return node
            if can_scroll:
                scroll()
        except (ElementTree.ParseError, subprocess.SubprocessError):
            pass
        time.sleep(1)
    raise RuntimeError(f"Android Agent Hub label did not appear: {label}")


def open_agents():
    deadline = time.monotonic() + 45
    while time.monotonic() < deadline:
        try:
            root = screen()
            agents = find(root, "Agents")
            if agents is not None:
                tap(agents)
                return
            skip = find(root, "Skip for now")
            if skip is not None:
                tap(skip)
            else:
                scroll()
        except (ElementTree.ParseError, subprocess.SubprocessError):
            pass
        time.sleep(1)
    raise RuntimeError("Unable to open Android Agent Hub after first-run setup")


def main():
    password = sys.argv[1]
    open_agents()
    tap(wait_for("Server password", can_scroll=True))
    adb("shell", "input", "text", password)
    adb("shell", "input", "keyevent", "66")
    tap(wait_for("Connect to OpenCode", can_scroll=True))
    wait_for("OpenCode connected")
    print("Android Agent Hub connected to the authenticated OpenCode server.")


if __name__ == "__main__":
    main()
