# Changelog

What changed in each release of Nod for desktop. `pnpm release <version>`
moves the Unreleased list under the new version, and the release workflow
publishes that section as the release notes.

## Unreleased

## 0.3.0 — 2026-11-16

- Search a meeting's transcript: type in the find bar on the Transcript tab,
  or press Cmd+F on a Mac and Ctrl+F on Windows and Linux. Every match is
  highlighted, and Enter moves to the next one.
- Summaries cover a long meeting from its start. Before, a meeting longer
  than about an hour could be summarized from its last part only. Qwen3.5 4B
  is now the recommended summary model and reads a two-hour meeting whole,
  as do the other Qwen3.5 and Gemma 4 models.
- More summary models to choose from: Gemma 4 E2B for computers with 8 GB of
  memory, which keeps to the meeting's language better than Qwen3.5 2B,
  Gemma 4 E4B for 12 GB, Qwen3.5 9B for 16 GB, and Qwen3.6 35B and Gemma 4
  31B for 48 GB.
- A smaller download of the Parakeet speech model for older computers.
- Built on a newer Electron, with its security fixes.

## 0.2.0 — 2026-10-30

- Nod keeps its data in a folder of its own, apart from the earlier Nod app
  for Mac, and moves what it already saved there on its first start.
- On a Mac, test copies of 0.1.1 don't update to this version: install it
  again from the release, and allow Nod to use the microphone and its
  keychain item when macOS asks.
- Summaries are written in the language of the meeting more reliably.
- More summary models to choose from, from Qwen3.5 2B for older computers
  to Gemma 4 26B for those with 24 GB of memory. With several downloaded, pick
  the one Nod uses with Use.
- A summary or a shared note edited on two devices at once keeps both
  changes. Before, a line added on one device could disappear when the other
  saved.
- When the relay refuses this computer, Nod says the relay may be older than
  the app, not only that the clock may be off.
- Built on a newer Electron, with its security fixes.

## 0.1.1 — 2026-10-28

- Builds for Intel Macs are made the same way as for Apple silicon.

## 0.1.0 — 2026-10-28

- Nod updates itself on macOS and Windows: a new version downloads in the
  background and installs when Nod restarts, never while you record. On Linux,
  Nod tells you when a new version is out.
- Settings → Updates shows the version you run and lets you turn automatic
  checks off.
