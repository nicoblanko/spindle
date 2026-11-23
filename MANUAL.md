# Spindle manual

Spindle is a macOS DJ app played with Traktor Scratch timecode vinyl (or
from the laptop, or from a DJ controller). It is laid out in four pages:

| Page | What it's for |
|---|---|
| **Organize** | Sort the library, tag and colour tracks, build sets |
| **Mark** | Beatgrid, cues and loop slots per track |
| **Mix** | Two decks and the track list, for playing out |
| **Sessions** | Recordings of your mixes, with tracklists, and export |

Switch pages with the page bar at the bottom, or **Tab** / **⇧Tab**.

---

## 1. Getting started

### What you need
- macOS 15.7 or later.
- Music files in a folder (Spindle reads a folder, for example in Dropbox;
  nothing is imported from Traktor).
- To play with vinyl: two turntables, Traktor Scratch timecode records and
  a class-compliant sound card with phono inputs. Spindle is built and
  tested on an Allen & Heath Xone:24C with two Technics SL-1210 MK2.

### First launch
1. On **Organize**, click **Choose music folder…** and pick your music
   folder. **Add files…** adds files or folders from anywhere else.
2. Spindle analyses the tracks: tempo (BPM), key, mood, energy, intro and
   outro type, and length.
3. Pick the audio device in the top bar (speaker icon) and start the audio
   engine (power icon).
4. Choose how to play, with the three mode icons in the top bar:
   - **Vinyl:** Traktor timecode records.
   - **Laptop:** Spindle plays on its own (keyboard, mouse or a DJ controller).
   - **Simulated vinyl:** virtual turntables, for trying things out
     without a sound card.

### The top bar
- **Audio device** (speaker): the sound card. Spindle finds the Xone again
  after it's unplugged and reconnected.
- **Engine** (power / restart): start, stop or restart the audio. The
  latency readout shows the sample rate and buffer size.
- **Timecode vinyl** (barcode): the record type per deck (see 5.3).
- **MIDI mapping** (piano keys): connect controllers (see 6).
- **Keyboard shortcuts** (keyboard, or **⌘/**): see and change every key (see 8).

---

## 2. Organize

The library on the left, the track list in the middle, and the set builder
or inspector on the right.

### Library (left)
- **Smart lists:** Marked, Tagged, In a set, Coloured.
- **Folders**, **sets** (playlists, in folders if you like; deleted ones
  are kept 30 days in *Recently deleted*), **tags** and **tempo groups**.
- Every section can be collapsed.
- Click a set or tag to see its tracks. Drag tracks onto a tag to tag them.
- **Tempo groups:** *Make tempo groups* groups tracks at 4% tempo steps,
  counting half and double time as the same tempo. *Make genre groups*
  makes groups from tempo ranges per genre (hip hop, house, techno, drum &
  bass). Groups are shown as a tree with genre folders; each group's range
  can be edited (*Edit range…*), with the option to also match at half or
  double tempo.
- Keys: **1** puts the keys in the library, **2** in the track list. In the
  library, ↑ ↓ move, ← → close and open folders, Return renames.

### Track list (middle)
A grid like Airtable:
- Built-in columns: Track, Folder, BPM, Key, Mood, Energy, Intro, Outro,
  Length, Tempo group, Tags, Marked, Colour.
- **Your own columns** (*Add a column*): single or multiple select, text,
  number, checkbox, rating.
- **Filter**, **group** and **sort** on any column, and keep combinations
  as **views** (*Save as view…*), which you can switch back to on any page.
- **Row colour** per track.
- ↑ ↓ move, space pre-listens, ← → skip 10 s.

### Set builder and inspector (right)
- With a set open: running time, energy and tempo curve, drag to reorder,
  the transition between each pair of tracks (clashes in red). Tracks
  already in the set are greyed in the list.
- With tracks selected: tags, sets, rating, notes and the track's Mark
  status, with **Open in Mark →**.

### Quick cards (every page)
- **⇧C** colour the selected tracks: ← → pick, 0–9 jump, Return applies.
- **⇧S** put the selected tracks in a set: type to find a set or name a
  new one, ↑ ↓ pick, Return adds (or takes them out again if they're all in
  it already).

---

## 3. Mark

Prepare a track for playing: beatgrid, cues and loop slots. Nothing is
placed automatically except a suggested grid.

- **Beatgrid:** tempo and downbeat are detected; *Detect again* redoes it
  (your cues and loops stay). Fine-tune with ±0.01 BPM, ×2 / ÷2, and nudge
  the grid earlier or later (**[** **]**). **D** puts bar 1 on the playhead.
  Turn on the metronome (**C**): if it drifts from the kick, fix the BPM;
  if it's early or late, nudge.
- **Cues:** **Q** adds a cue on the beat at the playhead. Keys **1–9** jump
  to a cue, **⇧1–9** move it to the playhead. Each cue gets a colour you pick.
- **Loop slots:** **L** adds a 4-bar loop on the beat at the playhead; set
  its length in bars and its in-point.
- **Marked:** **M** flags the track as ready to play.
- Moving around: space plays, ← → one bar, ⇧← ⇧→ one beat, ↑ ↓ previous
  or next track, − / = zoom.
- The pre-listen plays to its own output and is never recorded.

---

## 4. Mix

The track list at the top (same library and views as Organize, with its own
columns) and the two decks below.

### Track list
- **Dim what doesn't fit:** greys out tracks whose key or tempo doesn't fit
  a playing deck.
- **Pre-listen** a track in the headphones while you play: on the Xone:24C
  it plays on outputs 5–6 (the AUX/USB channel), so press that channel's
  **CUE** on the mixer to hear it.
- ↑ ↓ move, space pre-listens (over a deck: plays or stops that deck),
  ← → skip 10 s, **Z** loads on deck A, **M** on deck B.
- *Played* counts what you've played; **Reset** starts a fresh list.

### Decks
- Two waveforms per deck: the whole track and a zoomed view. Scroll, drag
  or click to move; pinch or ⌘-scroll to zoom.
- **Album art** next to the waveform (toggle in the deck header).
- **Cue pads 1–4**, **loop slots** (press again to let the track run on),
  **beat loops** (half / double), **filter** and **echo** per deck.
- In Laptop mode: **▶**, **CUE**, **SYNC**, tempo fader (±8, ±16, ±50%),
  nudge ‹ ›, and a built-in mixer (volume per deck and a crossfader).

---

## 5. Playing with timecode vinyl

### 5.1 Connecting (Xone:24C)
- Turntables into the phono inputs of channels 1 and 2. Set the rear USB
  switches to **PH**, so the timecode reaches the Mac.
- Set channels 1 and 2 to **USB**, so you hear Spindle.
- Each deck's input and output pair can be changed in the deck's settings.

### 5.2 Absolute and relative (ABS / REL, per deck)
- **ABS:** the place of the needle on the record is the place in the track,
  as in Traktor. Drop the needle anywhere and the track plays from there.
  The start of the record is the start of the track.
- **REL:** only the record's speed and direction count; the track carries
  on from where it is when you move the needle.

### 5.3 Record types
Per deck, under *Timecode vinyl*:
- **Traktor MK2** (both sides). The side is found by itself.
- Traktor MK1 (first edition), side A or B.
- Serato CV02, side A or B, and Serato CD (not yet tried on real Serato records).

### 5.4 How the deck follows the record (ABS)
- **Needle on the record = music; needle off = silence.** There's no
  carrying on after the needle is lifted.
- **Needle drop:** the deck waits silently until it has read where the
  needle is (about a tenth of a second), then starts exactly there, so
  there's no slide from the old spot.
- **Lead-in:** with the needle on the edge, before the first groove, the
  deck clock counts up from a few seconds below zero and the track starts
  as the needle reaches the first groove. Scratching and rocking the record across the
  start works as you'd expect.
- **Spins and scratches:** the deck follows the record. During very fast
  spins the position can't be read for a moment; the speed is followed,
  and as soon as the record reads again the track snaps into place with a
  short crossfade.
- **Past the end:** if the needle is beyond the end of the track, the
  waveform says so; move it towards the start of the record.

### 5.5 Limits
- At the sound card's 44.1 kHz, speeds above about 8× (hard backspins)
  can't be read at all; the track snaps back into place afterwards.
- Occasionally a very hard backspin can briefly play forwards (being
  worked on).

---

## 6. DJ controllers (MIDI)

Any class-compliant MIDI controller can be mapped with **MIDI learn**:
open **MIDI mapping** (piano keys in the top bar), click **Learn** next to
an action, then press the button or move the control.

- **Absolute knobs** (like the Akai MPK mini's) only take over once they
  reach the current value (soft takeover); the panel shows how far off a
  knob still is.
- **Actions per deck:** play, CUE, sync, tempo, volume, cue 1–4, loop on/off,
  loop ÷2 / ×2, filter, echo, load the highlighted track, jog touch, jog
  turn, jog outer ring.
- **Global:** crossfader, browse knob, record.
- Play, CUE, sync, tempo, volume, crossfader and the jog wheels drive the
  decks in **Laptop** mode.

### Jog wheels
- **Touch the top** to hold the track; turning it then scratches.
- **Turn without touching**, or the **outer ring**: bends the tempo while
  playing, searches while stopped.
- **Calibrate** (bottom of the MIDI mapping panel): mark the wheel, click
  Calibrate, turn it exactly one full turn, click Done. One turn of the jog
  then moves the track as far as one turn of a record.

### CUE (like a CDJ)
- Playing: back to the cue point, stopped.
- Stopped at the cue point: plays while held, goes back when released.
  Press PLAY while holding to keep playing.
- Stopped elsewhere: back to the cue point.

### Browse and load
The browse knob moves the highlight in the Mix track list; the load buttons
load the highlighted track.

### AlphaTheta Omnis-Duo (being tested)
There is no ready-made mapping yet: AlphaTheta's MIDI list isn't available,
so the mapping is being made from what the unit sends. To help:
1. Connect the Omnis-Duo, choose **Laptop** mode and pick the Omnis-Duo
   as the audio device.
2. Open **MIDI mapping** and tick **Log MIDI**.
3. Press every button, turn every knob and fader, touch and turn both jog
   wheels, and press the pads in each pad mode. Pause briefly between
   controls and note the order.
4. Click **Show log** and send `spindle.log`.

---

## 7. Sessions

- Press **REC** to record the mix: the mixer's record or master send (if
  your sound card has one as an input), or Spindle's own output of both
  decks. Recordings are 24-bit WAV.
- The **tracklist** is logged automatically with timestamps.
- **Export WAV…**, **Export MP3…** (320 kbps) or **Export AAC…**;
  **Copy tracklist** or **Save tracklist…**; **Show in Finder**.

---

## 8. Keyboard shortcuts

All of these can be changed in **Keyboard shortcuts** (⌘/): click a key and
press a new one; Esc cancels. A key already used on the same page swaps over.

| Where | Action | Default |
|---|---|---|
| Everywhere | Next / previous page | Tab / ⇧Tab |
| | Colour the selected tracks | ⇧C |
| | Put the selected tracks in a set | ⇧S |
| Organize | Keys in the library / track list | 1 / 2 |
| | Previous / next | ↑ / ↓ |
| | Pre-listen play / stop | Space |
| | Back / forward 10 s (library: close / open folder) | ← / → |
| | Rename (library) | Return |
| Mark | Play / stop | Space |
| | Back / forward one bar | ← / → |
| | Back / forward one beat | ⇧← / ⇧→ |
| | Previous / next track | ↑ / ↓ |
| | Zoom out / in | − / = |
| | Nudge grid earlier / later | [ / ] |
| | Bar 1 here | D |
| | Click on / off | C |
| | Marked on / off | M |
| | New cue / new loop slot | Q / L |
| | Jump to cue / set cue | 1–9 / ⇧1–9 |
| Mix | Previous / next track | ↑ / ↓ |
| | Pre-listen play / stop (over a deck: that deck) | Space |
| | Pre-listen back / forward 10 s | ← / → |
| | Load on deck A / B | Z / M |

---

## 9. Troubleshooting

- **The log:** `~/Library/Logs/spindle.log` records what the decks are
  doing (reading the record or not, needle drops, jumps). It's the first
  thing to look at, or to send, when something behaves oddly.
- **The Xone isn't found:** reconnect it; Spindle picks it up again. If not,
  restart the engine from the top bar.
- **A deck doesn't react to the record:** check the record type for that
  deck (5.3), that the Xone's rear switches are on PH, and the deck's input
  pair.
- **Opening Spindle on another Mac:** the app isn't notarized by Apple, so
  macOS may block it the first time. Allow it under System Settings →
  Privacy & Security → **Open Anyway**.

### For development
- `SPINDLE_CAPTURE=1` records each deck's raw timecode input to
  `~/Library/Logs/spindle-capture-A/B.wav`.
- `SPINDLE_REPLAY=<file.wav>` replays a capture through a deck offline and
  writes a trace; `SPINDLE_SELFTEST=1` runs the self-tests. Both run without
  a window.
- `SPINDLE_MIDILOG=1` logs all incoming MIDI (same as *Log MIDI*).

---

## 10. Building

Open `Spindle.xcodeproj` in Xcode 26 or later and run the Spindle scheme.

Spindle is free software under the GNU GPL, version 3 or later; see
[LICENSE](LICENSE).
