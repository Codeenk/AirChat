# AirChat v1.6.0 — notification correctness + build-pipeline modernization

This release is a correctness and maintenance pass. It does not touch the
cryptography, the transport, the local storage format, or the relay.

## Fixed

- **Notifications no longer vanish while a chat is open.** Every notification
  path was gated on "is the app in the foreground?", so *any* foreground state
  suppressed notifications for *every* conversation. A message from a second
  contact or a group was silently swallowed while you were reading a different
  chat. Only the conversation you actually have open is suppressed now;
  everything else (and everything while backgrounded) still notifies.

- **1:1 messages are no longer mislabelled with a group name.** A personal
  message from someone who also shares a group with you was titled
  `<Group> • <Name>`. The background push path inferred the group from the
  sender's *message history* — any earlier group message from that person was
  enough — instead of from the message being delivered. The notification is now
  keyed to the group the fetched payload actually belongs to, so a personal
  message shows the person (and stacks under them), and a group message shows
  the group.

## Modernized

- **Built-in Kotlin.** `android.gradle.properties` now sets
  `android.builtInKotlin=true` (requires AGP 9+ and Flutter 3.47+). AGP compiles
  Kotlin itself, so `mobile_scanner` no longer applies the legacy Kotlin Gradle
  Plugin and Flutter's "future versions will fail to build" warning is gone.

- **GitHub Actions moved off Node 20** (deprecated on the runners):
  `actions/checkout@v7`, `actions/cache@v6`, `actions/upload-artifact@v7`,
  `actions/setup-java@v6`, `softprops/action-gh-release@v3`. The Release
  workflow's tag guard also tolerates `+build` / `-prerelease` suffixes now.

- **Dropped `sqlcipher_flutter_libs`.** The resolved version was `0.7.0+eol`,
  an end-of-life stub that ships no native code at all (its own description
  says to use `package:sqlite3` 3.x instead). `sqflite_sqlcipher` already
  bundles SQLCipher itself via `net.zetetic:sqlcipher-android`. Removing the
  stub changes nothing at runtime.

## Not changed

- Cryptography, transport, storage, and the relay are untouched.
- Group messaging still uses a shared symmetric group key, not an MLS ratchet
  (see `SECURITY_DESIGN.md` §3.3).
- Still no independent security audit. The threat model's limits are unchanged.
