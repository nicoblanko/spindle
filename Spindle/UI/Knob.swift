//
//  Knob.swift
//  Spindle
//
//  A flat rotary knob: drag up or down to turn (hold ⌥ for fine), scroll
//  works too, double-click to reset. Bipolar knobs (the filter) rest in
//  the middle and draw their arc from there.
//

import AppKit
import SwiftUI

struct Knob: View {
    let value: Double
    var range: ClosedRange<Double> = 0...1
    var bipolar = false
    var size: CGFloat = 36
    var label: String? = nil
    var tint: Color = Theme.ink
    let onChange: (Double) -> Void
    @State private var dragStart: Double?

    private var fraction: Double { (value - range.lowerBound) / (range.upperBound - range.lowerBound) }
    private var rest: Double { bipolar ? (range.lowerBound + range.upperBound) / 2 : range.lowerBound }
    private var isOff: Bool { abs(value - rest) < 0.01 }

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                // 270° travel, gap at the bottom.
                Circle()
                    .trim(from: 0, to: 0.75)
                    .stroke(Theme.control, style: StrokeStyle(lineWidth: 3, lineCap: .butt))
                    .rotationEffect(.degrees(135))
                arc
                    .stroke(isOff ? Theme.inkFaint : tint, style: StrokeStyle(lineWidth: 3, lineCap: .butt))
                    .rotationEffect(.degrees(135))
                Circle().fill(Theme.panelRaised).padding(6)
                Rectangle()
                    .fill(isOff ? Theme.inkMuted : Theme.ink)
                    .frame(width: 2, height: size / 2 - 8)
                    .offset(y: -(size / 4 - 2))
                    .rotationEffect(.degrees(-135 + 270 * fraction))
            }
            .frame(width: size, height: size)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    if dragStart == nil { dragStart = value }
                    let fine = NSEvent.modifierFlags.contains(.option) ? 0.2 : 1
                    let span = range.upperBound - range.lowerBound
                    var v = (dragStart ?? value) - Double(g.translation.height) / 160 * span * fine
                    v = min(max(v, range.lowerBound), range.upperBound)
                    if bipolar && abs(v - rest) < span * 0.02 { v = rest }     // a detent in the middle
                    onChange(v)
                }
                .onEnded { _ in dragStart = nil })
            .simultaneousGesture(TapGesture(count: 2).onEnded { onChange(rest) })
            .help("Drag up or down · ⌥ fine · double-click resets")
            if let label {
                Text(label).font(.system(size: 9, weight: .medium)).tracking(0.3)
                    .foregroundStyle(isOff ? Theme.inkFaint : Theme.inkMuted)
                    .lineLimit(1)
            }
        }
    }

    private var arc: some Shape {
        let a = bipolar ? min(0.5, fraction) : 0
        let b = bipolar ? max(0.5, fraction) : fraction
        return Circle().trim(from: a * 0.75, to: b * 0.75)
    }
}

/// The six FX as a row of knobs.
struct FXKnobs: View {
    let fx: ClipFX
    var size: CGFloat = 36
    var spacing: CGFloat = 10
    var tint: Color = Theme.ink
    let onChange: (FXKind, Double) -> Void

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(FXKind.allCases) { kind in
                Knob(value: fx[kind], range: kind.bipolar ? -1...1 : 0...1, bipolar: kind.bipolar,
                     size: size, label: kind == .filter ? (fx.filter < -0.01 ? "LP" : fx.filter > 0.01 ? "HP" : "FILTER") : kind.short,
                     tint: tint) { onChange(kind, $0) }
            }
        }
    }
}
