# AirChat v1.5.8+35 — Android secret-messenger hardening

This release is a focused security and privacy hardening pass for the Android
client. It is not a magic "unhackable" or "untappable" release. The goal is
stronger remote/server secrecy and less accidental in-device leakage, with
honest documentation of the real limits.

## What this release does

- Adds a written threat model and security design doc so the app's security
  posture is defined instead of implied.
- Reduces leakage-prone diagnostic logging. Logs and crash reports no longer
  dump raw exception text or full push-payload objects; diagnostics stay short
  and operational.
- Tightens how notifications are described and treated in code comments, so the
  notification path is handled as a real leakage surface on unlocked devices.
- Keeps user-facing error messages where they matter, while avoiding verbose
  internal exception dumping in UI paths.

## What this improves

- Less sensitive detail accidentally ending up in local logs and diagnostic
  files.
- Clearer security boundaries for future changes.
- A better-documented starting point for review and further hardening.

## Post-release fixes (this tree)

- Remove the unused `_redactStack` in `push_service.dart` — the only analyzer
  warning, which would fail the strict `flutter analyze` CI step.
- `android/gradle.properties`: daemon heap lowered from `-Xmx8G` (Meta 4G) to
  `-Xmx3g` (Meta 768m). An 8 GB daemon cannot fit on a 6–8 GB RAM machine and
  gets killed mid-build ("Gradle build daemon disappeared", exit 143).
- Local release builds must use JDK 17/21 via `JAVA_HOME` (CI already pins
  Temurin 17). A system JDK 26 breaks AGP's `JdkImageTransform` (jlink) on
  `core-for-system-modules.jar` with `Could not resolve all files for
  configuration ':connectivity_plus:androidJdkImage'`.

## What this does not do

- It does not make the app "unhackable" or "untappable" in a broad sense.
- It does not defeat spying on an unlocked device that is already open and in
  use.
- It does not remove the need for good device hygiene, strong lock-screen
  habits, and careful handling of screenshots, backups, clipboard, and sharing.
- It does not replace independent security review.

## Verification

This release should be built and checked through the normal Android CI gate:

- `flutter pub get`
- `dart format --output=none --set-exit-if-changed lib test`
- `flutter analyze --no-pub --no-fatal-infos --no-fatal-warnings`
- `flutter test`
- `flutter build apk --release --split-per-abi --obfuscate --split-debug-info=build/symbols`

## Artifacts

Release APKs and checksums should be attached from the CI run for this tag.
Do not hand-edit the binaries; they should come directly from the release
workflow.

## Notes for reviewers and users

- The threat model doc is the place to check what the app protects and what it
  does not.
- If a future change touches crypto, push, notifications, storage, background
  services, permissions, or logging, it should be checked against the design
  doc.
- Security claims should match the implementation. Overclaiming is a defect.
