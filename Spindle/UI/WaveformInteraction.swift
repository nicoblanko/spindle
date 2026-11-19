//
//  WaveformInteraction.swift
//  Spindle
//
//  Mouse and trackpad handling for the deck waveforms, laid over them as a
//  transparent AppKit view (SwiftUI has no scroll-wheel events):
//    • scroll (wheel or two fingers, either direction) moves through the track
//    • drag moves it like a hand on a record; a click without moving reports
//      where it landed
//    • pinch, or ⌘-scroll, zooms
//

import AppKit
import SwiftUI

struct WaveformInteraction: NSViewRepresentable {
    /// Scroll or drag by this many points (positive = later in the track).
    var onScroll: (CGFloat) -> Void
    /// A click at this fraction of the width (0…1).
    var onClick: ((CGFloat) -> Void)? = nil
    /// Drag started at a fraction of the width: overview uses it to seek
    /// absolutely while dragging.
    var dragsAbsolutely = false
    /// Zoom by a factor (> 1 = zoom in).
    var onZoom: ((CGFloat) -> Void)? = nil

    func makeNSView(context: Context) -> InteractionView {
        let view = InteractionView()
        view.owner = self
        return view
    }

    func updateNSView(_ view: InteractionView, context: Context) {
        view.owner = self
    }

    final class InteractionView: NSView {
        var owner: WaveformInteraction?
        private var lastDrag: NSPoint?
        private var moved = false

        override var acceptsFirstResponder: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func scrollWheel(with event: NSEvent) {
            guard let owner else { return }
            // Wheel mice report lines; trackpads report points.
            let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
            if event.modifierFlags.contains(.command), let zoom = owner.onZoom {
                zoom(1 + event.scrollingDeltaY * scale * 0.01)
                return
            }
            // Horizontal swipes and vertical scrolling both move through the
            // track. Content follows the fingers: swipe left = later.
            let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
                ? -event.scrollingDeltaX : -event.scrollingDeltaY
            owner.onScroll(delta * scale)
        }

        override func magnify(with event: NSEvent) {
            owner?.onZoom?(1 + event.magnification)
        }

        override func mouseDown(with event: NSEvent) {
            lastDrag = convert(event.locationInWindow, from: nil)
            moved = false
            if owner?.dragsAbsolutely == true, let p = lastDrag {
                owner?.onClick?(p.x / max(bounds.width, 1))
            }
        }

        override func mouseDragged(with event: NSEvent) {
            let p = convert(event.locationInWindow, from: nil)
            defer { lastDrag = p }
            guard let owner, let last = lastDrag else { return }
            moved = true
            if owner.dragsAbsolutely {
                owner.onClick?(min(max(p.x / max(bounds.width, 1), 0), 1))
            } else {
                owner.onScroll(last.x - p.x)          // drag the waveform like a record
            }
        }

        override func mouseUp(with event: NSEvent) {
            if !moved, owner?.dragsAbsolutely == false, let p = lastDrag {
                owner?.onClick?(p.x / max(bounds.width, 1))
            }
            lastDrag = nil
        }
    }
}
