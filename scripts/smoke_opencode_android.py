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
        if label == "Server password" and node.get("password") == "true":
            return node
        if node.get("resource-id", "").endswith("/" + label):
            return node
        for value in (node.get("text"), node.get("content-desc"), node.get("resource-id")):
            if label in (value or "").splitlines():
                return node
    return None


def visible_labels():
    return [
        label for node in screen().iter("node")
        if node.get("password") != "true"
        if (label := node.get("content-desc") or node.get("text") or node.get("resource-id"))
    ][:25]


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
    print("Visible Agent Hub labels:", visible_labels())
    raise RuntimeError(f"Android Agent Hub label did not appear: {label}")


def open_agents():
    deadline = time.monotonic() + 45
    while time.monotonic() < deadline:
        try:
            root = screen()
            skip = find(root, "neuromesh.onboarding.skip")
            if skip is None:
                skip = find(root, "Skip for now")
            if skip is None:
                skip = find(root, "Skip")
            if skip is not None:
                tap(skip)
            else:
                agents = find(root, "neuromesh.agents")
                if agents is None:
                    agents = find(root, "Agents")
                if agents is not None:
                    tap(agents)
                    return
                scroll()
        except (ElementTree.ParseError, subprocess.SubprocessError):
            pass
        time.sleep(1)
    print("Visible setup labels:", visible_labels())
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
    try:
        main()
    except Exception:
        from pathlib import Path
        from os import environ
        filename = Path(environ.get("RUNNER_TEMP", "/tmp")) / "neuromesh-android-smoke.png"
        with filename.open("wb") as screenshot:
            subprocess.run(("adb", "exec-out", "screencap", "-p"), stdout=screenshot, timeout=10, check=False)
        raise
