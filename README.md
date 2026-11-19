# Spindle

A native macOS DJ app controlled by Traktor Scratch timecode vinyl: Traktor's
decks combined with Ableton's clip launcher, laid out in pages like DaVinci
Resolve (Organize, Prep, Mix, Sessions).

## Status

All four pages work:

- **Organize:** library from a folder (subfolders are crates), analysis of
  BPM, key, energy, intro and outro type. Keys are shown as a colour on a
  12-colour wheel plus a mood (Dark = minor, Bright = major): neighbouring
  colours mix well. For a selected track, "Good next tracks" lists what
  mixes after it (same key, lift, drop, mood change). Playlists and
  folders for sets, holding tracks from anywhere on disk. Tags: your own
  (put on by hand) and tempo groups (a BPM range, optionally energy and
  mood, that tracks join by themselves); "Make tempo groups" splits the
  library into ranges no wider than 6% so every track in a group mixes
  with the others. Playlists, tags or folders can be the Mix page's
  columns.
- **Prep:** suggested beatgrid (tempo and downbeat), cues 1 IN, 2 DROP,
  3 BRK, 4 OUT and loops, all editable on a zoomable waveform; clip FX
  (filter, echo) and a mix-ready flag.
- **Mix:** clip grid with one column per crate above the two timecode decks.
  Clips that mix with a playing deck (key and tempo) are outlined in its
  colour. Cue pads, beat loops, filter and echo per deck.
- **Sessions:** records the mix (the mixer's master send or Spindle's own
  output) to 24-bit WAV with an automatic tracklist; export to WAV,
  MP3 (320 kbps, via LAME) or AAC, copy or save the tracklist.
- **Timecode:** Traktor Scratch MK1 and MK2 vinyl through a class-compliant
  sound card (built and tested on an Allen & Heath Xone:24C with two
  Technics SL-1210 MK2). Absolute and relative modes, needle drops, and
  playing on when the needle leaves the record. Simulated turntables
  (MK1 or MK2) when no sound card is connected.
- **Laptop mode:** play without turntables. Play/pause, cue, sync (tempo
  and beats), tempo ±8/16/50%, nudge, and a built-in mixer with volume
  faders and a crossfader. Choose Vinyl, Laptop or Simulated vinyl under
  "Play with".
- **Waveforms:** scroll, drag or click the whole-track strip and the zoomed
  waveform to move through a track; pinch or ⌘-scroll to zoom.
- **MIDI learn** for controllers such as the Akai MPK mini, with soft
  takeover for absolute knobs.

## Building

Open `Spindle.xcodeproj` in Xcode 26 or later and run the Spindle scheme
(macOS 15.7+).

## Licence

Copyright (C) 2026 Rein Blank

Spindle is free software: you can redistribute it and/or modify it under the
terms of the GNU General Public License as published by the Free Software
Foundation, either version 3 of the License, or (at your option) any later
version (SPDX: GPL-3.0-or-later). It is distributed in the hope that it will
be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. The full licence text is
in [LICENSE](LICENSE).

Being GPL, Spindle can reuse code from other GPL projects such as Mixxx
(GPL-2.0-or-later), xwax and libKeyFinder, with their copyright notices kept.
