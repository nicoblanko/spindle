//
//  Theme.swift
//  Spindle
//
//  Tokens from the Spindle style guide. Dark, flat, square; one orange accent
//  used only for the active page, selection and playhead. "Darker" swaps the
//  surfaces for near-black ones; everything else stays.
//

import AppKit
import Observation
import SwiftUI

/// Look settings you can change while the app runs: the darker variant of
/// the theme and the waveform style. Views read them through `Theme`, so
/// they redraw when one changes.
@Observable
final class LookSettings {
    static let shared = LookSettings()

    /// Black & white: pure black surfaces, every colour turned to the grey
    /// of the same brightness.
    var darker = UserDefaults.standard.bool(forKey: "look.darker") {
        didSet {
            UserDefaults.standard.set(darker, forKey: "look.darker")
            LookFlags.mono = darker
        }
    }

    init() { LookFlags.mono = darker }
    var waveStyle = WaveStyle(rawValue: UserDefaults.standard.string(forKey: "look.wave") ?? "") ?? .threeBand {
        didSet { UserDefaults.standard.set(waveStyle.rawValue, forKey: "look.wave") }
    }
}

/// Read by `Color(hex:)` from any thread, so it can't live on the main actor.
nonisolated enum LookFlags {
    nonisolated(unsafe) static var mono = false
}

/// How waveforms are coloured.
enum WaveStyle: String, CaseIterable, Identifiable {
    /// Bass, mids and highs as three layers (blue, amber, white).
    case threeBand = "3-Band"
    /// One shape, coloured by its sound: red bass, green mids, blue highs.
    case rgb = "RGB"
    /// One colour, loudness inside the peaks.
    case mono = "Mono"
    var id: String { rawValue }
}

enum Theme {
    private static var d: Bool { LookSettings.shared.darker }
    static var bg: Color { d ? Color(hex: 0x000000) : Color(hex: 0x161618) }
    static var panel: Color { d ? Color(hex: 0x0a0a0a) : Color(hex: 0x1f1f22) }
    static var panelRaised: Color { d ? Color(hex: 0x141414) : Color(hex: 0x2a2a2e) }
    static var control: Color { d ? Color(hex: 0x1f1f1f) : Color(hex: 0x35353a) }
    static var line: Color { d ? Color(hex: 0x282828) : Color(hex: 0x3e3e44) }
    static var ink: Color { d ? Color(hex: 0xf2f2f2) : Color(hex: 0xe2e2e4) }
    static var inkMuted: Color { Color(hex: 0x9a9aa1) }
    static var inkFaint: Color { Color(hex: 0x6c6c73) }
    static var accent: Color { d ? Color(hex: 0xffffff) : Color(hex: 0xf08a24) }
    static var accentSoft: Color { d ? Color(hex: 0x2e2e2e) : Color(hex: 0x4a2f16) }
    static var onAccent: Color { d ? Color(hex: 0x000000) : Color(hex: 0x161618) }
    static var deckA: Color { d ? Color(hex: 0xe8e8e8) : Color(hex: 0x4fa3ff) }
    static var deckB: Color { d ? Color(hex: 0x8a8a8a) : Color(hex: 0xc06a2b) }
    static var match: Color { d ? Color(hex: 0xc8c8c8) : Color(hex: 0x5fd37a) }
    static var warn: Color { d ? Color(hex: 0xffffff) : Color(hex: 0xff5a4f) }
    static var waveLow: Color { Color(hex: 0x3d6fb3) }
    static var waveMid: Color { Color(hex: 0xa8b4c4) }
    static var waveHigh: Color { Color(hex: 0xeef2f7) }

    static let space1: CGFloat = 4
    static let space2: CGFloat = 8
    static let space3: CGFloat = 12
    static let space4: CGFloat = 16
    static let radiusSm: CGFloat = 2
    static let radiusMd: CGFloat = 4

    // Inter for the interface, JetBrains Mono for every number. Falls back to
    // the system faces when the fonts aren't installed.
    private static let hasInter = NSFont(name: "Inter", size: 12) != nil
    private static let hasMono = NSFont(name: "JetBrains Mono", size: 12) != nil

    static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        hasInter ? .custom("Inter", size: size).weight(weight) : .system(size: size, weight: weight)
    }

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        hasMono ? .custom("JetBrains Mono", size: size).weight(weight) : .system(size: size, weight: weight, design: .monospaced)
    }

    static let title = sans(15, .semibold)
    static let body = sans(13)
    static let label = sans(11, .medium)
    static let caption = sans(11)
    static let readoutXL = mono(28)
    static let readout = mono(15)
    static let readoutSm = mono(11)
}

extension Color {
    /// In Black & white, every colour becomes the grey of its brightness.
    nonisolated init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xff) / 255, g = Double((hex >> 8) & 0xff) / 255, b = Double(hex & 0xff) / 255
        if LookFlags.mono {
            let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
            self.init(.sRGB, red: y, green: y, blue: y)
        } else {
            self.init(.sRGB, red: r, green: g, blue: b)
        }
    }
}

/// Uppercase, tracked label style from the guide.
struct LabelText: View {
    let text: String
    var color: Color = Theme.inkMuted
    init(_ text: String, color: Color = Theme.inkMuted) {
        self.text = text
        self.color = color
    }
    var body: some View {
        Text(text.uppercased())
            .font(Theme.label)
            .tracking(0.44)
            .foregroundStyle(color)
    }
}

/// Flat button: control fill at rest, accent fill when primary.
struct FlatButtonStyle: ButtonStyle {
    var primary = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.body)
            .padding(.horizontal, Theme.space3)
            .padding(.vertical, 5)
            .foregroundStyle(primary ? Theme.onAccent : Theme.ink)
            .background(primary ? Theme.accent : (configuration.isPressed ? Theme.line : Theme.control))
            .opacity(configuration.isPressed ? 0.85 : 1)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusMd))
    }
}
