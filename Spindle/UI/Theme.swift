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

/// Look settings you can change while the app runs: the colour theme and
/// the waveform style. Views read them through `Theme`, so they redraw when
/// one changes.
@Observable
final class LookSettings {
    static let shared = LookSettings()

    var theme: AppTheme = LookSettings.savedTheme {
        didSet {
            UserDefaults.standard.set(theme.rawValue, forKey: "look.theme")
            LookFlags.saturation = theme.saturation
        }
    }

    init() { LookFlags.saturation = theme.saturation }

    private static var savedTheme: AppTheme {
        if let raw = UserDefaults.standard.string(forKey: "look.theme"), let t = AppTheme(rawValue: raw) { return t }
        return UserDefaults.standard.bool(forKey: "look.darker") ? .ink : .studio     // the old switch
    }

    var waveStyle = WaveStyle(rawValue: UserDefaults.standard.string(forKey: "look.wave") ?? "") ?? .threeBand {
        didSet { UserDefaults.standard.set(waveStyle.rawValue, forKey: "look.wave") }
    }
}

/// The colour themes, from full colour to none.
enum AppTheme: String, CaseIterable, Identifiable {
    /// The original: dark grey panels, orange accent, full colour.
    case studio = "Studio"
    /// In between: darker panels, every colour toned halfway to grey.
    case dusk = "Dusk"
    /// Black and white: pure black, white, greys only.
    case ink = "Ink"
    var id: String { rawValue }

    /// How much colour is kept (1 = all, 0 = greys).
    var saturation: Double {
        switch self {
        case .studio: 1
        case .dusk: 0.45
        case .ink: 0
        }
    }

    var summary: String {
        switch self {
        case .studio: "Original colours"
        case .dusk: "Darker, muted colours"
        case .ink: "Black and white"
        }
    }
}

/// Read by `Color(hex:)` from any thread, so it can't live on the main actor.
nonisolated enum LookFlags {
    nonisolated(unsafe) static var saturation = 1.0
}

/// How waveforms are coloured.
enum WaveStyle: String, CaseIterable, Identifiable {
    /// Bass, mids and highs as three layers (blue, amber, white).
    case threeBand = "3-Band"
    /// One shape, coloured by its sound: red bass, green mids, blue highs.
    case rgb = "RGB"
    /// One solid colour.
    case mono = "Mono"
    var id: String { rawValue }
}

enum Theme {
    private static var t: AppTheme { LookSettings.shared.theme }
    /// Studio, Dusk, Ink.
    private static func pick(_ studio: UInt32, _ dusk: UInt32, _ ink: UInt32) -> Color {
        switch t {
        case .studio: Color(hex: studio)
        case .dusk: Color(hex: dusk)
        case .ink: Color(hex: ink)
        }
    }
    static var bg: Color { pick(0x161618, 0x0e0e10, 0x000000) }
    static var panel: Color { pick(0x1f1f22, 0x151517, 0x0a0a0a) }
    static var panelRaised: Color { pick(0x2a2a2e, 0x1d1d20, 0x141414) }
    static var control: Color { pick(0x35353a, 0x28282c, 0x1f1f1f) }
    static var line: Color { pick(0x3e3e44, 0x2f2f34, 0x282828) }
    static var ink: Color { pick(0xe2e2e4, 0xe6e6e8, 0xf2f2f2) }
    static var inkMuted: Color { Color(hex: 0x9a9aa1) }
    static var inkFaint: Color { Color(hex: 0x6c6c73) }
    static var accent: Color { pick(0xf08a24, 0xf08a24, 0xffffff) }
    static var accentSoft: Color { pick(0x4a2f16, 0x3a2a1c, 0x2e2e2e) }
    static var onAccent: Color { pick(0x161618, 0x0e0e10, 0x000000) }
    static var deckA: Color { pick(0x4fa3ff, 0x4fa3ff, 0xe8e8e8) }
    static var deckB: Color { pick(0xc06a2b, 0xc06a2b, 0x8a8a8a) }
    static var match: Color { pick(0x5fd37a, 0x5fd37a, 0xc8c8c8) }
    static var warn: Color { pick(0xff5a4f, 0xff5a4f, 0xffffff) }
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
    /// Every colour is pulled towards the grey of its brightness as far as
    /// the theme asks: not at all in Studio, halfway in Dusk, fully in Ink.
    nonisolated init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xff) / 255, g = Double((hex >> 8) & 0xff) / 255, b = Double(hex & 0xff) / 255
        let k = LookFlags.saturation
        let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
        self.init(.sRGB, red: y + (r - y) * k, green: y + (g - y) * k, blue: y + (b - y) * k)
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
