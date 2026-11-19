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

GPL-3.0-or-later; see [LICENSE](LICENSE). Being GPL, Spindle can reuse code
from other GPL projects such as Mixxx (GPL-2.0-or-later), xwax and
libKeyFinder, with their copyright notices kept.
