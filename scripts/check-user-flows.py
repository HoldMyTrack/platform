#!/usr/bin/env python3
"""Checks apps/docs/user-flows.json against the apps' UI tests and documents: every test a flow
names exists, every UI test is named by a flow, every state is an apps/docs/ui-states.json entry,
every spec is an apps/docs/SPEC.md requirement, and every flow has one entry per app (tests, a
reason, or null) and its own id. Lists the flows with a test not written yet (null) without
failing on them.

UI tests: Android's under androidTest/.../flows, iOS's in HoldMyTrackUITests. The shot tests
(UiShotsTest, UIShotsTests) belong to ui-states.json instead.
"""
import glob
import json
import os
import re
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
FLOWS = os.path.join(ROOT, "apps", "docs", "user-flows.json")
STATES = os.path.join(ROOT, "apps", "docs", "ui-states.json")
SPEC = os.path.join(ROOT, "apps", "docs", "SPEC.md")
ANDROID = "apps/android/holdmytrack/app/src/androidTest/kotlin/dev/holdmytrack/android/flows/*.kt"
IOS = "apps/ios/HoldMyTrackUITests/*.swift"
SHOTS = {"UIShotsTests"}


# Kotlin: a fun whose annotations include @Test, whatever else is beside it.
ANDROID_CLASS = r"^\s*(?:\w+\s+)*class (\w+)"
ANDROID_TEST = r"@Test\b(?:\([^)]*\))?(?:\s*@\w+(?:\([^)]*\))?)*\s+fun (\w+)\s*\("
# Swift: what XCTest runs, a func named test… that takes nothing and isn't private.
IOS_CLASS = r"^\s*(?:final\s+)?class (\w+)\s*:\s*XCTestCase"
IOS_TEST = r"^\s*(?:@\w+\s+)*func (test\w+)\s*\(\s*\)"


def tests(pattern, class_re, test_re):
    """{"Class.method"} for every test in the files [pattern] matches, each credited to the
    class it sits in."""
    found = set()
    for path in glob.glob(os.path.join(ROOT, pattern)):
        text = open(path, encoding="utf-8").read()
        classes = list(re.finditer(class_re, text, re.M))
        for i, c in enumerate(classes):
            if c.group(1) in SHOTS:
                continue
            end = classes[i + 1].start() if i + 1 < len(classes) else len(text)
            found |= {f"{c.group(1)}.{t}" for t in re.findall(test_re, text[c.end():end], re.M)}
    return found


def main():
    apps = {
        "android": tests(ANDROID, ANDROID_CLASS, ANDROID_TEST),
        "ios": tests(IOS, IOS_CLASS, IOS_TEST),
    }
    requirements = set(re.findall(r"^### (FR-\d+\.\d+)\b", open(SPEC, encoding="utf-8").read(), re.M))
    states = {s["id"] for s in json.load(open(STATES, encoding="utf-8"))["states"]}
    doc = json.load(open(FLOWS, encoding="utf-8"))

    errors, todo, ids = [], {app: [] for app in apps}, set()
    named = {app: set() for app in apps}
    for feature in doc["features"]:
        for flow in feature["flows"]:
            fid = f'{feature["id"]}/{flow["id"]}'
            spec = flow.get("spec", feature.get("spec"))
            if spec not in requirements:
                errors.append(f"{fid}: no apps/docs/SPEC.md requirement {spec!r}")
            if fid in ids:
                errors.append(f"{fid}: listed twice")
            ids.add(fid)
            for s in flow.get("states", []):
                if s not in states:
                    errors.append(f"{fid}: no ui-states.json entry {s!r}")
            for app, have in apps.items():
                if app not in flow:
                    errors.append(f"{fid}: no {app} entry (tests, a reason, or null)")
                    continue
                value = flow[app]
                if value is None:
                    todo[app].append(fid)
                elif isinstance(value, str):
                    if not value.strip():
                        errors.append(f"{fid}: {app}'s reason is empty")
                elif isinstance(value, list) and value:
                    for t in value:
                        if t not in have:
                            errors.append(f"{fid}: no {app} test {t}")
                        named[app].add(t)
                else:
                    errors.append(f"{fid}: {app} is neither a list of tests, a reason nor null")
    for app, have in apps.items():
        for t in sorted(have - named[app]):
            errors.append(f"{app} test {t} is in no flow")

    for app, flows in todo.items():
        if flows:
            print(f"{app}: {len(flows)} flows with no test yet: {', '.join(flows)}")
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print(f"user-flows.json: {len(ids)} flows, every named test found and every UI test named")
    return 0


if __name__ == "__main__":
    sys.exit(main())