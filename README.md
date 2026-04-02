# ChordSaver

macOS app for **recording short guitar takes per chord** from a built-in chord library. Each take is saved as a **24-bit WAV**; you can **export** all takes in a session to a folder of your choice.

## Features

- **Chord library** — Searchable list with categories; includes fretboard diagrams (movable shapes across roots).
- **Audio input** — Pick a macOS input device; recordings use `AVAudioEngine`.
- **Takes** — Record/stop per chord; numbered takes per chord, waveform preview and level info on the last take.
- **Session export** — **Session → Export Session…** (⌘⇧E) copies WAV files to a user-selected folder with sanitized filenames.

Session audio lives under **Application Support** (`ChordSaver/Sessions/<session-id>/`).

## Requirements

- **macOS 14** or later  
- **Xcode** with Swift 5 (open `ChordSaver.xcodeproj`)

## Building

1. Open `ChordSaver.xcodeproj` in Xcode.  
2. Select the **ChordSaver** scheme and run (⌘R).

Unit tests: **ChordSaverTests** target.

## Chord data

Bundled voicings ship as `ChordSaver/Resources/chords.json`. To regenerate from the generator script:

```bash
python3 Scripts/generate_chords.py > ChordSaver/Resources/chords.json
```

(Review the script’s output path comments if your layout differs.)

## Permissions

The app is **sandboxed** with **audio input** and **user-selected file access** (for export). macOS will prompt for microphone access when recording.

## Repository layout

| Path | Purpose |
|------|---------|
| `ChordSaver/` | SwiftUI app sources, assets, `chords.json` |
| `ChordSaverTests/` | Tests |
| `Scripts/generate_chords.py` | Optional chord JSON generator |
| `AGENTS.md` | Notes for AI/agents working in this repo |
