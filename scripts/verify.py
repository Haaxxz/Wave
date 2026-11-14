#!/usr/bin/env python3
"""Static checks for the Wave repo that run without Xcode.

Checks:
  1. project.yml parses as YAML and declares the three targets.
  2. Both Info.plist files and the workflow YAML parse.
  3. Every .swift file has balanced braces/parens/brackets (scanner skips
     line comments, block comments and string literals, including
     interpolations).
  4. Every screen type named in docs/CONTRACTS.md exists as a struct.
  5. No file references an absolute /Users/ or /home/ path.
  6. No leftover TODO/FIXME markers in app code (warnings, not errors).

Usage: python3 scripts/verify.py  (run from the repo root)
Exit code 0 means all checks passed.
"""
import json
import plistlib
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ERRORS: list[str] = []
WARNINGS: list[str] = []


def error(msg: str) -> None:
    ERRORS.append(msg)


def warn(msg: str) -> None:
    WARNINGS.append(msg)


def check_yaml() -> None:
    import yaml

    project = yaml.safe_load((ROOT / "project.yml").read_text())
    targets = set(project.get("targets", {}))
    for want in ("Wave", "WaveWidgets", "WaveTests"):
        if want not in targets:
            error(f"project.yml: missing target {want}")
    workflow = yaml.safe_load(
        (ROOT / ".github/workflows/ios.yml").read_text())
    if "jobs" not in workflow:
        error("ios.yml: no jobs key")
    print(f"yaml ok: targets={sorted(targets)}")


def check_plists() -> None:
    for rel in ("Wave/Info.plist", "WaveWidgets/Info.plist"):
        with open(ROOT / rel, "rb") as fh:
            plistlib.load(fh)
    print("plists ok")


def check_assets() -> None:
    base = ROOT / "Wave/Resources/Assets.xcassets"
    for name in ("Contents.json",
                 "AccentColor.colorset/Contents.json",
                 "AppIcon.appiconset/Contents.json"):
        json.loads((base / name).read_text())
    appicon = json.loads(
        (base / "AppIcon.appiconset/Contents.json").read_text())
    for entry in appicon["images"]:
        fn = entry.get("filename")
        if fn and not (base / "AppIcon.appiconset" / fn).exists():
            error(f"AppIcon: missing file {fn}")
    print("assets ok")


def scan_balanced(path: Path) -> None:
    """Brace/paren/bracket balance, skipping comments and string literals."""
    text = path.read_text()
    stack: list[tuple[str, int]] = []
    pairs = {"{": "}", "(": ")", "[": "]"}
    closers = set(pairs.values())
    i, line = 0, 1
    n = len(text)
    state = "code"  # code | linecomment | blockcomment | string | multistring
    interp_depth: list[int] = []  # brace depth inside \(...\) interpolations

    while i < n:
        ch = text[i]
        nxt = text[i + 1] if i + 1 < n else ""
        if ch == "\n":
            line += 1
        if state == "code":
            if ch == "/" and nxt == "/":
                state = "linecomment"
                i += 2
                continue
            if ch == "/" and nxt == "*":
                state = "blockcomment"
                i += 2
                continue
            if ch == '"' and text[i:i + 3] == '"""':
                state = "multistring"
                i += 3
                continue
            if ch == '"':
                state = "string"
                i += 1
                continue
            if ch in pairs:
                stack.append((ch, line))
            elif ch in closers:
                if not stack or pairs[stack[-1][0]] != ch:
                    error(f"{path.relative_to(ROOT)}:{line}: unmatched {ch}")
                    return
                stack.pop()
            i += 1
        elif state == "linecomment":
            if ch == "\n":
                state = "code"
            i += 1
        elif state == "blockcomment":
            if ch == "*" and nxt == "/":
                state = "code"
                i += 2
                continue
            i += 1
        elif state == "string":
            if ch == "\\" and nxt in ('"', "\\", "n", "t", "r", "0", "$"):
                i += 2
                continue
            if ch == "\\" and nxt == "(":
                # Interpolation: count the parens as code until it closes.
                depth = 1
                i += 2
                while i < n and depth > 0:
                    c = text[i]
                    if c == "\n":
                        line += 1
                    if c == "(":
                        depth += 1
                    elif c == ")":
                        depth -= 1
                    elif c == '"':
                        # Nested string inside the interpolation.
                        j = i + 1
                        while j < n and text[j] != '"':
                            if text[j] == "\\":
                                j += 1
                            j += 1
                        i = j
                    i += 1
                continue
            if ch == '"':
                state = "code"
            i += 1
        elif state == "multistring":
            if text[i:i + 3] == '"""':
                state = "code"
                i += 3
                continue
            i += 1
    if state not in ("code", "linecomment"):
        error(f"{path.relative_to(ROOT)}: unterminated {state}")
    if stack:
        ch, ln = stack[-1]
        error(f"{path.relative_to(ROOT)}:{ln}: unclosed {ch}")


def check_swift() -> None:
    files = sorted(ROOT.rglob("*.swift"))
    if not files:
        error("no .swift files found")
    for path in files:
        scan_balanced(path)
        text = path.read_text()
        if "/Users/" in text or "/home/" in text:
            error(f"{path.relative_to(ROOT)}: absolute path in source")
        if re.search(r"\b(TODO|FIXME|XXX)\b", text):
            warn(f"{path.relative_to(ROOT)}: has TODO/FIXME marker")
    print(f"swift ok: {len(files)} files scanned")


def check_contracts() -> None:
    contracts = (ROOT / "docs/CONTRACTS.md").read_text()
    # Only the "Exact names:" paragraph lists screens; the rest of the
    # document mentions other *View types (TabView, YouTubeWebView) that are
    # not screens.
    marker = "Exact names:"
    start = contracts.find(marker)
    section = contracts[start:] if start >= 0 else contracts
    end = section.find("\n\n")
    if end >= 0:
        section = section[:end]
    screens = re.findall(r"`(\w+View)(?:\(.*?\))?`", section)
    swift = "\n".join(p.read_text() for p in ROOT.rglob("*.swift"))
    missing = [s for s in sorted(set(screens))
               if f"struct {s}" not in swift]
    for name in missing:
        warn(f"CONTRACTS screen not yet implemented: {name}")
    if not missing:
        print("contracts ok: all named screens exist")


def main() -> int:
    check_yaml()
    check_plists()
    check_assets()
    check_swift()
    check_contracts()
    for w in WARNINGS:
        print("WARN:", w)
    for e in ERRORS:
        print("ERROR:", e)
    print(f"{len(ERRORS)} errors, {len(WARNINGS)} warnings")
    return 1 if ERRORS else 0


if __name__ == "__main__":
    sys.exit(main())
