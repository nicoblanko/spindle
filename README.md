# Spindle

A native macOS DJ app controlled by Traktor Scratch timecode vinyl: Traktor's
decks combined with Ableton's clip launcher, laid out in pages like DaVinci
Resolve (Organize, Prep, Mix, Sessions).

## Status

- **Timecode:** reads Traktor Scratch MK1 and MK2 vinyl through a
  class-compliant sound card (built and tested on an Allen & Heath Xone:24C
  with two Technics SL-1210 MK2). Absolute and relative modes, needle drops,
  and playing on when the needle leaves the record.
- **Simulated turntables** when no sound card is connected, generating MK1 or
  MK2 timecode.
- **Organize:** library from a folder, analysis of BPM, key (Camelot),
  energy, intro and outro type; compatibility filtering and a key × energy map.

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
