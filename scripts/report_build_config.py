#!/usr/bin/env python3
"""Create private Flutter build defines without printing credentials."""
import argparse
import base64
import json
import os
import re
from urllib.parse import urlsplit
from pathlib import Path


def write_config(destination, environment):
    values = {key: environment.get(key, "").strip() for key in (
        "NEUROMESH_REPORT_ENDPOINT", "NEUROMESH_REPORT_BOT_TOKEN", "NEUROMESH_REPORT_CHAT_ID")}
    token, chat = values["NEUROMESH_REPORT_BOT_TOKEN"], values["NEUROMESH_REPORT_CHAT_ID"]
    if token or chat:
        if not re.fullmatch(r"[0-9]+:[A-Za-z0-9_-]{20,}", token) or not re.fullmatch(r"-?[1-9][0-9]{0,18}", chat):
            raise ValueError("Both developer report secrets must be valid; no values are logged.")
    endpoint = values["NEUROMESH_REPORT_ENDPOINT"]
    if endpoint:
        try:
            parsed = urlsplit(endpoint)
            valid = parsed.scheme == "https" and bool(parsed.hostname) and not parsed.username and not parsed.password and not parsed.query and not parsed.fragment
        except ValueError:
            valid = False
        if not valid:
            raise ValueError("Developer report endpoint must be an HTTPS URL without credentials, query or fragment.")
    if environment.get("REQUIRE_DEVELOPER_REPORT_DELIVERY") == "true" and not (token or endpoint):
        raise ValueError("Developer report delivery must be configured before publishing. Add the private report secrets in repository settings.")
    for key, value in values.items():
        if value:
            print("::add-mask::" + value.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A"))
            print("::add-mask::" + base64.b64encode((key + "=" + value).encode()).decode())
    destination = Path(destination)
    descriptor = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as output:
        json.dump(values, output)
    print("Developer report delivery: " + ("configured" if token or values["NEUROMESH_REPORT_ENDPOINT"] else "not configured"))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("destination")
    write_config(parser.parse_args().destination, os.environ)
