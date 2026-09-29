#!/usr/bin/env python3
"""Hardware-free consistency checks for the iOS rebuild.

1. Every bundled JS file parses (node --check).
2. Every window.AndBridge.* method in __BridgeShim.js has a matching
   `case "..."` in SpotifyBridge.swift (and vice versa).
3. Every name in InjectionLoader.pageStart/playerStack has a Resources/JS file.
4. Theme style element IDs are defined in ThemeJS.swift.

Run from repo root:  python3 ci/check_consistency.py
Exit non-zero with a list of violations.
"""
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
APP = ROOT / "MuseMobileiOS"
JS = APP / "Resources" / "JS"
errs: list[str] = []


def fail(msg: str) -> None:
    errs.append(msg)
    print("FAIL:", msg)


# ---- 1. node --check ----
js_files = sorted(JS.glob("*.js"))
print(f"js files: {len(js_files)}")
node_ok = True
try:
    subprocess.run(["node", "--version"], capture_output=True, check=True)
except Exception:
    fail("node not installed: install node to run `node --check` on bundled JS")
    node_ok = False
if node_ok:
    for f in js_files:
        r = subprocess.run(["node", "--check", str(f)], capture_output=True, text=True)
        if r.returncode != 0:
            fail(f"{f.name} does not parse: {r.stderr[:300]}")
    print("node --check done")

# ---- 2. bridge method parity ----
shim = (JS / "__BridgeShim.js").read_text(encoding="utf-8")
m = re.search(r"var METHODS = \[(.*?)\];", shim, re.DOTALL)
shim_methods = set(re.findall(r'"(\w+)"', m.group(1))) if m else set()
bridge = (APP / "Bridge" / "SpotifyBridge.swift").read_text(encoding="utf-8")
swift_cases = set()
for mcase in re.finditer(r"case ((?:\"\w+\",?\s*)+):", bridge):
    swift_cases.update(re.findall(r'"(\w+)"', mcase.group(1)))
print(f"shim methods: {len(shim_methods)}, swift cases: {len(swift_cases)}")
# JS-only stubs: answered synchronously in the shim, never posted to native.
# isWoke must return a bool synchronously; WKScriptMessageHandler is one-way,
# so the shim hardcodes `true` (Android: activity window visible check).
JS_ONLY = {"isWoke"}
for meth in sorted(shim_methods - swift_cases - JS_ONLY):
    fail(f"shim method '{meth}' has no Swift case")
for case in sorted(swift_cases - shim_methods):
    fail(f"Swift case '{case}' missing from shim METHODS")

# ---- 3. injection order coverage ----
# Array payloads (pageStart/playerStack) plus dynamic loads via
# InjectionLoader.jsResource("...") / Bundle.main.url(forResource: "...")
# in InjectionLoader.swift + SpotifyWebView.swift. The dynamic set covers
# BrowserSpoof, GoogleSpoof, FbGdprBypass, ClassicLoginButton,
# LoginDetection, LogoutCheck, __BridgeShim.
loader = (APP / "WebView" / "InjectionLoader.swift").read_text(encoding="utf-8")
webview = (APP / "WebView" / "SpotifyWebView.swift").read_text(encoding="utf-8")
names = re.findall(r'"([A-Z][A-Za-z]+)"', loader)
# keep only known payload names (drop unrelated string literals by requiring a js file or list membership)
on_disk = {p.stem for p in js_files}
for name in sorted(set(names)):
    if name in ("JS",):  # directory literal, not a payload
        continue
    # string literals like "normal"/"musemobile" are lowercase-first; payload names are CamelCase
    if name not in on_disk:
        # only flag if it appears inside the pageStart/playerStack array regions
        fail(f"payload '{name}' referenced in InjectionLoader but no {name}.js on disk")
print(f"injection names checked: {len(set(names))}")

# ---- 3b. dynamic jsResource / Bundle.main.url coverage ----
dynamic_refs: set[str] = set()
for src in (loader, webview):
    # jsResource("Name") direct calls
    dynamic_refs.update(re.findall(r'jsResource\(\s*"(\w+)"\s*\)', src))
    # jsResource(cond ? "A" : "B") ternary (BrowserSpoof/GoogleSpoof)
    for mjs in re.finditer(r"jsResource\(([^)]*)\)", src):
        dynamic_refs.update(re.findall(r'"(\w+)"', mjs.group(1)))
    # Bundle.main.url/path(forResource: "Name", ...) (__BridgeShim)
    dynamic_refs.update(re.findall(r'forResource:\s*"(\w+)"', src))
array_names = set(re.findall(r'"([A-Z][A-Za-z0-9_]+)"', loader)) & on_disk
referenced = (array_names | dynamic_refs) - {"JS"}
print(f"dynamic jsResource/Bundle refs: {sorted(dynamic_refs)}")
for name in sorted(referenced):
    if (JS / f"{name}.js").is_file():
        continue
    # Only flag names that look like payloads (CamelCase / dunder); skip
    # unrelated literals that happened to match (e.g. directory names).
    if re.fullmatch(r"(?:__)?[A-Z][A-Za-z0-9_]*", name):
        fail(f"dynamic payload '{name}' has no Resources/JS/{name}.js on disk")

# ---- 3c. every bundled resource must be in the Xcode Resources phase ----
pbxproj = (ROOT / "MuseMobileiOS.xcodeproj" / "project.pbxproj").read_text(encoding="utf-8")
for f in js_files:
    if f"{f.name} in Resources" not in pbxproj:
        fail(f"{f.name} not in project.pbxproj Resources phase")
if "silent.wav in Resources" not in pbxproj:
    fail("silent.wav not in project.pbxproj Resources phase")
print("pbxproj Resources phase checked")

# ---- 3d. orphan .js files (on disk, referenced nowhere) ----
orphans = sorted(on_disk - referenced)
for name in orphans:
    fail(f"orphan {name}.js: on disk but referenced nowhere (arrays, jsResource, Bundle)")
print(f"orphan check done ({len(orphans)} orphan(s))")

# ---- 4. theme element ids ----
theme = (APP / "WebView" / "ThemeJS.swift").read_text(encoding="utf-8")
for eid in ("musemobile-amoled-theme", "musemobile-custom-css", "musemobile-lyrics-style"):
    if eid not in theme:
        fail(f"theme element id '{eid}' missing from ThemeJS.swift")
for var in ("--spl-accent", "--spl-accent-bright", "--spl-accent-rgb"):
    if var not in theme:
        fail(f"theme var '{var}' missing from ThemeJS.swift")
print("theme ids checked")

if errs:
    print(f"\n{len(errs)} violation(s)")
    sys.exit(1)
print("\nconsistency OK")
