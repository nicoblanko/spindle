//
//  Theme.swift
//  Spindle
//
//  Tokens: black and white, flat, square. White marks the active page,
//  selection and playhead; each deck's colour (picked in the Colours panel)
//  is the only colour.
//

import AppKit
import Observation
import SwiftUI

/// Look settings you can change while the app runs: each deck's colour and
/// whether the colour panel is open. Views read them through `Theme`, so
/// they redraw when one changes.
@Observable
final class LookSettings {
    static let shared = LookSettings()

    /// The colour panel on the right is open.
    var panelOpen = UserDefaults.standard.bool(forKey: "look.panel") {
        didSet { UserDefaults.standard.set(panelOpen, forKey: "look.panel") }
    }

    /// Each deck's colour: its waveforms, header and active controls. The
    /// only colour in the black-and-white theme, so the decks stay apart.
    var deckAColor = DeckColor(rawValue: UserDefaults.standard.string(forKey: "look.deckA") ?? "") ?? .blue {
        didSet { UserDefaults.standard.set(deckAColor.rawValue, forKey: "look.deckA") }
    }
    var deckBColor = DeckColor(rawValue: UserDefaults.standard.string(forKey: "look.deckB") ?? "") ?? .orange {
        didSet { UserDefaults.standard.set(deckBColor.rawValue, forKey: "look.deckB") }
    }
}

/// A deck's colour, in three groups.
enum DeckColor: String, CaseIterable, Identifiable {
    // Neutrals
    case white = "White", pearl = "Pearl", silver = "Silver", stone = "Stone", steel = "Steel", graphite = "Graphite"
    // Vivid
    case blue = "Blue", cyan = "Cyan", teal = "Teal", green = "Green", lime = "Lime", yellow = "Yellow",
         gold = "Gold", orange = "Orange", red = "Red", pink = "Pink", magenta = "Magenta", violet = "Violet"
    // Soft
    case sky = "Sky", ice = "Ice", mint = "Mint", sage = "Sage", lemon = "Lemon", sand = "Sand",
         peach = "Peach", coral = "Coral", rose = "Rose", lilac = "Lilac"
    var id: String { rawValue }

    enum Group: String, CaseIterable, Identifiable {
        case neutrals = "Neutrals", vivid = "Vivid", soft = "Soft"
        var id: String { rawValue }
        var colors: [DeckColor] { DeckColor.allCases.filter { $0.group == self } }
    }

    var group: Group {
        switch self {
        case .white, .pearl, .silver, .stone, .steel, .graphite: .neutrals
        case .blue, .cyan, .teal, .green, .lime, .yellow, .gold, .orange, .red, .pink, .magenta, .violet: .vivid
        default: .soft
        }
    }

    var hex: UInt32 {
        switch self {
        case .white: 0xffffff
        case .pearl: 0xe4dfd6
        case .silver: 0x9aa0a8
        case .stone: 0xb3a998
        case .steel: 0x6f7f90
        case .graphite: 0x5c5c62
        case .blue: 0x4fa3ff
        case .cyan: 0x3fd0e0
        case .teal: 0x1fc8a0
        case .green: 0x5fd37a
        case .lime: 0xb6e93a
        case .yellow: 0xf2d13c
        case .gold: 0xf5a700
        case .orange: 0xf08a24
        case .red: 0xff5a4f
        case .pink: 0xff6fa8
        case .magenta: 0xe040fb
        case .violet: 0x9b7bd9
        case .sky: 0x9cc9ff
        case .ice: 0xc4f1f7
        case .mint: 0x9ff0c8
        case .sage: 0xb7d3a8
        case .lemon: 0xfff1a0
        case .sand: 0xe8cfa0
        case .peach: 0xffc39e
        case .coral: 0xff9a8a
        case .rose: 0xffaec9
        case .lilac: 0xc9b6ff
        }
    }
    var color: Color { Color(hex: hex, exact: true) }
}

/// Black and white: pure black surfaces, white text and greys in between.
/// The deck colours are the only colour.
enum Theme {
    static var bg: Color { Color(hex: 0x000000) }
    static var panel: Color { Color(hex: 0x0a0a0a) }
    static var panelRaised: Color { Color(hex: 0x141414) }
    static var control: Color { Color(hex: 0x1f1f1f) }
    static var line: Color { Color(hex: 0x282828) }
    static var ink: Color { Color(hex: 0xf2f2f2) }
    static var inkMuted: Color { Color(hex: 0x9a9aa1) }
    static var inkFaint: Color { Color(hex: 0x6c6c73) }
    static var accent: Color { Color(hex: 0xffffff) }
    static var accentSoft: Color { Color(hex: 0x2e2e2e) }
    static var onAccent: Color { Color(hex: 0x000000) }
    static var deckA: Color { LookSettings.shared.deckAColor.color }
    static var deckB: Color { LookSettings.shared.deckBColor.color }
    static var match: Color { Color(hex: 0xc8c8c8) }
    static var warn: Color { Color(hex: 0xffffff) }
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
    /// Every colour becomes the grey of its brightness (the theme is black
    /// and white), except `exact` ones: the deck colours you picked.
    nonisolated init(hex: UInt32, exact: Bool = false) {
        let r = Double((hex >> 16) & 0xff) / 255, g = Double((hex >> 8) & 0xff) / 255, b = Double(hex & 0xff) / 255
        let k = exact ? 1.0 : 0     // black and white, except the deck colours
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
