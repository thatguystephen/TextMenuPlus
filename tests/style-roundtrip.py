#!/usr/bin/env python3

import plistlib
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PLIST = ROOT / "Resources" / "com.schlub51.textmenuplus.styles.plist"
WHITELISTED_STYLES = [
    "bold",
    "italic",
    "boldItalic",
    "mono",
    "serifBold",
    "serifItalic",
    "serifBoldItalic",
    "script",
    "scriptBold",
    "gothic",
    "gothicBold",
    "hollow",
    "circled",
]
DETECTABLE = set(WHITELISTED_STYLES)
CORPUS = [
    "hello world",
    "HELLO WORLD",
    "MiXeD Case",
    "Text 123, punctuation!",
    "déjà vu, café, naïve",
    "N AND A stay latin",
]


def load_styles():
    with PLIST.open("rb") as handle:
        return plistlib.load(handle)


STYLES = load_styles()
BY_NAME = {style["name"]: style for style in STYLES}


def plain_candidate_should_replace(existing_plain, new_plain):
    if not existing_plain or not new_plain:
        return not existing_plain and bool(new_plain)
    existing_lower = existing_plain == existing_plain.lower()
    new_lower = new_plain == new_plain.lower()
    if new_lower and not existing_lower:
        return True
    if new_lower == existing_lower and new_plain < existing_plain:
        return True
    return False


def is_ascii(text):
    try:
        text.encode("ascii")
        return True
    except UnicodeEncodeError:
        return False


def build_reverse_info():
    reverse = {}
    for style in STYLES:
        name = style.get("name")
        style_map = style.get("map")
        if not isinstance(name, str) or not isinstance(style_map, dict):
            continue
        for plain, styled in style_map.items():
            if (
                isinstance(plain, str)
                and isinstance(styled, str)
                and styled
                and styled != plain
                and not is_ascii(styled)
            ):
                existing = reverse.get(styled)
                if existing is None or (
                    existing["name"] == name
                    and plain_candidate_should_replace(existing["plain"], plain)
                ):
                    reverse[styled] = {"plain": plain, "name": name}
    return reverse


REVERSE_INFO = build_reverse_info()
REVERSE_PLAIN = {
    styled: info["plain"]
    for styled, info in REVERSE_INFO.items()
    if isinstance(info.get("plain"), str)
}
COMBINE_MARKS = []
for style in STYLES:
    combine = style.get("combine")
    if isinstance(combine, str):
        for mark in combine:
            if mark and mark not in COMBINE_MARKS:
                COMBINE_MARKS.append(mark)


def strip_combines(text):
    result = text
    for mark in COMBINE_MARKS:
        result = result.replace(mark, "")
    return result


def plain_text(text):
    return "".join(REVERSE_PLAIN.get(ch, ch) for ch in strip_combines(text))


def apply_style(text, name):
    style_map = BY_NAME[name].get("map", {})
    return "".join(style_map.get(ch, ch) for ch in text)


def style_name_from_text(text):
    without_combine = strip_combines(text)
    counts = {}
    styled_count = 0
    letter_count = 0
    for ch in without_combine:
        if ch.isalpha():
            letter_count += 1
        info = REVERSE_INFO.get(ch)
        name = info.get("name") if isinstance(info, dict) else None
        if isinstance(name, str) and name and name in DETECTABLE:
            styled_count += 1
            counts[name] = counts.get(name, 0) + 1

    if styled_count < 2 or not counts:
        return None
    if letter_count > 0 and styled_count * 2 < letter_count:
        return None

    dominant_name = None
    dominant_count = 0
    for style in STYLES:
        name = style.get("name")
        count = counts.get(name, 0)
        if count > dominant_count:
            dominant_name = name
            dominant_count = count

    if dominant_count * 2 < styled_count:
        return None
    return dominant_name


def assert_equal(actual, expected, label):
    if actual != expected:
        print(f"FAIL {label}: expected {expected!r}, got {actual!r}", file=sys.stderr)
        sys.exit(1)


def assert_true(condition, label):
    if not condition:
        print(f"FAIL {label}", file=sys.stderr)
        sys.exit(1)


def assert_no_whitelisted_cross_ambiguity():
    seen = {}
    collisions = []
    for style_name in WHITELISTED_STYLES:
        for plain, styled in BY_NAME[style_name].get("map", {}).items():
            if not styled or styled == plain:
                continue
            existing = seen.get(styled)
            if existing is None:
                seen[styled] = (style_name, plain)
            elif existing != (style_name, plain):
                collisions.append((styled, existing, (style_name, plain)))
    if collisions:
        print("FAIL whitelisted cross-style ambiguity:", file=sys.stderr)
        for styled, first, second in collisions:
            print(f"  {styled!r}: {first!r} vs {second!r}", file=sys.stderr)
        sys.exit(1)


assert_no_whitelisted_cross_ambiguity()

for style_name in WHITELISTED_STYLES:
    for text in CORPUS:
        styled = apply_style(text, style_name)
        assert_equal(plain_text(styled), text, f"{style_name} plain round-trip for {text!r}")
        assert_equal(style_name_from_text(styled), style_name, f"{style_name} detection for {text!r}")

uppercase = "N AND A STAY LATIN"
assert_equal(style_name_from_text(uppercase), None, "plain uppercase style detection")
assert_equal(plain_text(uppercase), uppercase, "plain uppercase stays unchanged")

russian_artifacts = apply_style("na", "russian")
assert_true("И" in russian_artifacts and "Д" in russian_artifacts, "russian artifact fixture")
assert_equal(plain_text(russian_artifacts), "na", "russian artifacts cleaned by plain")
assert_equal(style_name_from_text(russian_artifacts), None, "russian artifacts are not auto-detected")

print("style round-trip tests passed: 13 detectable styles, 0 whitelisted ambiguities, uppercase anti-regression, russian artifact cleanup")
