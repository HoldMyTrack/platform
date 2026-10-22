# ADR-0049: Rules every client applies are written natively in each, and defined once by shared test cases

## Status

Accepted. The web and Android implement every rule in `testdata/client-rules/`; the iOS app will join them when it starts.

## Context

Some rules can't live on the server (ADR-0047) because they answer a tap or a drag before any round trip: the date slider's knobs, which activities the toolbar acts on, the track editor's operations, where photo markers sit. The web implements them in TypeScript and Android in Kotlin; iOS will need them in Swift. Each rule has a JSON file of cases in `testdata/client-rules/`, and the web and Android suites run every file, failing on one they don't implement.

The code is written by agents. That changes the cost of writing a rule three times, which is small, but not the cost of three implementations disagreeing, which a user sees as the apps behaving differently.

## Decision

- **Each client implements every shared rule in its own language**, as a function of values with no view, map or network, in the style of the code around it.
- **The cases are the definition.** A rule changes by editing its file first, then every implementation, in the same pull request; a bug in a rule is fixed by adding the failing case. A rule with no file is not shared, and differs between platforms on purpose or not at all.
- **Every client's suite runs every file**, and fails on a file it has no implementation for, so a new rule can't land on one platform alone.

## Alternatives considered

- **Kotlin Multiplatform**, one Kotlin module compiled for iOS. It adds a Gradle build to the iOS toolchain, an Objective-C-shaped bridge between Swift and the shared code, and a debugger that stops at that bridge. Agents writing the code remove none of that: the cost is in building, interop and debugging, not in typing.
- **The TypeScript rules run in an embedded JavaScript engine** on both phones. Every call crosses a bridge with serialized arguments, on paths as hot as a knob drag, and a stack trace on the phone points into bundled JavaScript.
- **Rules on the server.** Right for anything that can wait for a response, and ADR-0047 moves those there; a drag or a tap can't.

## Consequences

- **A rule change touches three files in three languages**, plus its case file. That is the price of keeping each app idiomatic and debuggable in its own tools.
- **The implementations agree only where the cases reach.** Hand-written cases cover what someone thought of; rounding and boundary differences slip past them, so the geometric and numeric rules also get generated cases checked within a tolerance.
- **The case format stays platform-neutral** (`testdata/client-rules/README.md`): plain JSON, no type or naming from any one language.
- **The iOS app starts with a spec**: its suite fails until it implements every file.