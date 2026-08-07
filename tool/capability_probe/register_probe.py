#!/usr/bin/env python3
"""Puts the probe bundle on a tier's launcher.

Installing a bundle is more than copying a directory: the launcher draws from
the app registry the tier keeps in its preferences, so a bundle nobody
registered is invisible even though it is installed. A gate cannot depend on
someone opening a file picker, so this writes the entry.

The app must be closed — preferences are read at launch and rewritten on exit,
so an edit made while it runs is overwritten by the running copy.
"""

import argparse
import json
import plistlib
import subprocess
import sys
from datetime import datetime, timezone

PROBE_ID = "com.makemind.probe.capability"
PROBE_NAME = "Capability probe"


def read_apps(domain: str) -> list:
    raw = subprocess.run(
        ["defaults", "read", domain, "flutter.apps.v1"],
        capture_output=True, text=True)
    if raw.returncode != 0:
        return []
    # `defaults read` prints the string with its quotes escaped; the value is
    # JSON, so decode it that way rather than parsing the plist syntax.
    text = raw.stdout.strip()
    if text.startswith('"') and text.endswith('"'):
        text = text[1:-1].replace('\\"', '"').replace('\\\\', '\\')
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        return []


def write_apps(domain: str, apps: list) -> None:
    subprocess.run(
        ["defaults", "write", domain, "flutter.apps.v1", "-string",
         json.dumps(apps, ensure_ascii=False)],
        check=True)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("domain", help="preferences domain, e.g. com.makemind.appplayerPro")
    parser.add_argument("--remove", action="store_true",
                        help="take the probe off the launcher again")
    args = parser.parse_args()

    if subprocess.run(["pgrep", "-f", args.domain], capture_output=True).returncode == 0:
        print(f"{args.domain} looks like it is running — close it first, or the "
              f"running copy will overwrite this entry", file=sys.stderr)
        return 2

    apps = [a for a in read_apps(args.domain) if a.get("id") != PROBE_ID]
    if not args.remove:
        apps.append({
            "id": PROBE_ID,
            "name": PROBE_NAME,
            "type": "bundle",
            "metadataJson": {
                "appId": PROBE_ID, "sourceKind": "localBundle",
                "name": PROBE_NAME, "version": "1.0.0",
                "description": "Every declared capability, each reporting its "
                               "own failure — the publish gate reads this.",
                "category": "developer",
            },
            "bundleId": PROBE_ID,
            "bundleVersion": "1.0.0",
            "dashboardLayout": "grid",
            "dashboardSize": "twoByTwo",
            "trustLevel": "basic",
            "lastUsedAt": datetime.now(timezone.utc).isoformat(),
        })
    write_apps(args.domain, apps)
    print(f"{'removed' if args.remove else 'registered'} {PROBE_NAME} in {args.domain}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
