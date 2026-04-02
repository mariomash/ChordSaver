#!/usr/bin/env python3
"""Emit ~720 guitar voicings as chords.json (movable shapes × roots × qualities)."""
from __future__ import annotations

import json
import sys
from pathlib import Path

ROOTS = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

# Semitone of open low E string at nut for naming (E = 4 in MIDI-ish mapping from C=0: E=4)
E_SEMI = 4
A_SEMI = 9


def fret_for_low_e_root(root_semi: int) -> int:
    """Fret on low E where note equals root (0..11)."""
    for f in range(0, 18):
        if (E_SEMI + f) % 12 == root_semi % 12:
            return f
    return 0


def fret_for_a_string_root(root_semi: int) -> int:
    for f in range(0, 18):
        if (A_SEMI + f) % 12 == root_semi % 12:
            return f
    return 0


def base_fret_from_strings(strings: list[int]) -> int:
    played = [s for s in strings if s >= 0]
    if not played:
        return 1
    m = min(played)
    return 1 if m == 0 else m


def shift_shape(strings: list[int], delta: int) -> list[int]:
    out = []
    for s in strings:
        if s < 0:
            out.append(-1)
        else:
            out.append(s + delta)
    return out


# Templates: 6 strings low->high, -1 mute. Values are RELATIVE to barre/root fret for E-shape/A-shape.
# E-shape major barre (root on string 6): e.g. F at 1: [1,3,3,2,1,1]
E_MAJ = [0, 2, 2, 1, 0, 0]  # relative to barre at root fret
E_MIN = [0, 2, 2, 0, 0, 0]
E_DOM7 = [0, 2, 0, 1, 0, 0]
E_MAJ7 = [0, 2, 1, 1, 0, 0]
E_MIN7 = [0, 2, 0, 0, 0, 0]
E_M7B5 = [0, 1, 2, 0, 3, 0]
E_DIM = [0, 1, 2, 0, 2, 0]
E_AUG = [0, 3, 2, 1, 0, 0]
E_SUS2 = [0, 2, 2, 2, 0, 0]
E_SUS4 = [0, 2, 2, 3, 0, 0]
E_ADD9 = [0, 2, 2, 1, 0, 2]

# A-shape (root on string 5): barre across string 5 at root; typical major [x,0,2,2,2,0] relative
A_MAJ = [-1, 0, 2, 2, 2, 0]
A_MIN = [-1, 0, 2, 2, 1, 0]
A_DOM7 = [-1, 0, 2, 0, 2, 0]
A_MAJ7 = [-1, 0, 2, 1, 2, 0]
A_MIN7 = [-1, 0, 2, 0, 1, 0]
A_M7B5 = [-1, 0, 1, 2, 0, 3]
A_DIM = [-1, 0, 1, 2, 0, 2]
A_AUG = [-1, 0, 3, 2, 2, 0]
A_SUS2 = [-1, 0, 2, 4, 2, 0]
A_SUS4 = [-1, 0, 2, 2, 3, 0]
A_ADD9 = [-1, 0, 2, 1, 0, 2]

QUALITIES = [
    ("", "major", "maj", E_MAJ, A_MAJ),
    ("m", "minor", "min", E_MIN, A_MIN),
    ("7", "dominant", "dom7", E_DOM7, A_DOM7),
    ("maj7", "major7", "maj7", E_MAJ7, A_MAJ7),
    ("m7", "minor7", "m7", E_MIN7, A_MIN7),
    ("m7b5", "half-dim", "m7b5", E_M7B5, A_M7B5),
    ("dim", "diminished", "dim", E_DIM, A_DIM),
    ("aug", "augmented", "aug", E_AUG, A_AUG),
    ("sus2", "sus2", "sus2", E_SUS2, A_SUS2),
    ("sus4", "sus4", "sus4", E_SUS4, A_SUS4),
    ("add9", "add9", "add9", E_ADD9, A_ADD9),
]


def clamp_frets(strings: list[int], cap: int = 17) -> list[int]:
    return [s if s < 0 else min(s, cap) for s in strings]


def build_chords() -> list[dict]:
    base: list[dict] = []
    idx = 0
    for ri, root in enumerate(ROOTS):
        root_semi = ri
        fe = fret_for_low_e_root(root_semi)
        fa = fret_for_a_string_root(root_semi)
        for suf, cat, qid, e_shape, a_shape in QUALITIES:
            name = root + suf
            es = clamp_frets(shift_shape(e_shape, fe))
            idx += 1
            base.append(
                {
                    "id": f"{name.lower().replace('#', 's')}_{qid}_e_{idx}",
                    "displayName": name,
                    "category": cat,
                    "strings": es,
                    "baseFret": base_fret_from_strings(es),
                    "fingers": None,
                }
            )
            ash = clamp_frets(shift_shape(a_shape, fa))
            idx += 1
            base.append(
                {
                    "id": f"{name.lower().replace('#', 's')}_{qid}_a_{idx}",
                    "displayName": name,
                    "category": cat,
                    "strings": ash,
                    "baseFret": base_fret_from_strings(ash),
                    "fingers": None,
                }
            )

    # ~792 entries: add two higher-position variants (+5 / +10 frets) for movable practice.
    out: list[dict] = []
    vid = 0
    for c in base:
        for shift in (0, 5, 10):
            vid += 1
            shifted = clamp_frets([s if s < 0 else s + shift for s in c["strings"]])
            out.append(
                {
                    "id": f"{c['id']}_p{shift}_{vid}",
                    "displayName": c["displayName"],
                    "category": c["category"],
                    "strings": shifted,
                    "baseFret": base_fret_from_strings(shifted),
                    "fingers": None,
                }
            )
    return out


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    out_path = root / "ChordSaver" / "Resources" / "chords.json"
    out_path.parent.mkdir(parents=True, exist_ok=True)
    chords = build_chords()
    out_path.write_text(json.dumps(chords, indent=2) + "\n", encoding="utf-8")
    print(f"Wrote {len(chords)} chords to {out_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
