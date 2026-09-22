#!/usr/bin/env python3
"""Build altstore/apps.json for a signed IPA (fills size + date automatically).

Usage (after ci/archive.sh):
  python3 ci/make_altstore.py --ipa build/export/MuseMobileiOS.ipa \\
      --user YOUR_GITHUB_USER --repo YOUR_IOS_REPO --tag v1.1.4-ios-smoke1 [--out altstore/apps.json]

Then commit + push, and add this URL as a source in AltStore:
  https://raw.githubusercontent.com/<user>/<repo>/main/altstore/apps.json
"""
import argparse
import datetime
import json
import os

APP_NAME = "MuseMobile"
BUNDLE_ID = "com.musemobile.ios"
VERSION = "1.1.4"
TINT = "1DB954"
ICON_PATH = "musemobile-ios/MuseMobileiOS/Assets.xcassets/AppIcon.appiconset/icon-1024.png"

p = argparse.ArgumentParser()
p.add_argument("--ipa", required=True, help="path to signed .ipa")
p.add_argument("--user", required=True, help="GitHub user/org")
p.add_argument("--repo", required=True, help="GitHub repo for the iOS project")
p.add_argument("--tag", required=True, help="release tag, e.g. v1.1.4-ios-smoke1")
p.add_argument("--out", default="altstore/apps.json")
a = p.parse_args()

size = os.path.getsize(a.ipa)
base = f"https://github.com/{a.user}/{a.repo}/releases/download/{a.tag}"
raw = f"https://raw.githubusercontent.com/{a.user}/{a.repo}/main"
now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

source = {
    "name": APP_NAME,
    "identifier": f"{BUNDLE_ID}.source",
    "subtitle": "Sideload source for MuseMobile iOS smoke builds",
    "description": "Smoke-test builds. Sideload only — no App Store distribution.",
    "iconURL": f"{raw}/{ICON_PATH}",
    "tintColor": TINT,
    "featuredApps": [BUNDLE_ID],
    "apps": [
        {
            "name": APP_NAME,
            "bundleIdentifier": BUNDLE_ID,
            "developerName": a.user,
            "subtitle": "Spotify web player wrapper + adblock (smoke build)",
            "version": VERSION,
            "versionDate": now,
            "versionDescription": "Smoke-1: see RELEASE_NOTES_1.1.4-ios-smoke1.md. Cipher/PoToken staged; downloads may fail.",
            "downloadURL": f"{base}/MuseMobileiOS.ipa",
            "localizedDescription": "iOS rebuild of MuseMobile for smoke testing. Install via AltStore; refresh every 7 days on a free Apple ID.",
            "iconURL": f"{raw}/{ICON_PATH}",
            "tintColor": TINT,
            "size": size,
            "screenshotURLs": [],
            "permissions": [],
        }
    ],
    "news": [],
}

os.makedirs(os.path.dirname(a.out) or ".", exist_ok=True)
with open(a.out, "w", encoding="utf-8") as f:
    json.dump(source, f, indent=2)
    f.write("\n")
print(f"wrote {a.out} (size={size})")
