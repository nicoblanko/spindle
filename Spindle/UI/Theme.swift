//
//  Theme.swift
//  Spindle
//
//  Tokens from the Spindle style guide. Dark, flat, square; one orange accent
//  used only for the active page, selection and playhead.
//

import AppKit
import SwiftUI

enum Theme {
    static let bg = Color(hex: 0x161618)
    static let panel = Color(hex: 0x1f1f22)
    static let panelRaised = Color(hex: 0x2a2a2e)
    static let control = Color(hex: 0x35353a)
    static let line = Color(hex: 0x3e3e44)
    static let ink = Color(hex: 0xe2e2e4)
    static let inkMuted = Color(hex: 0x9a9aa1)
    static let inkFaint = Color(hex: 0x6c6c73)
    static let accent = Color(hex: 0xf08a24)
    static let accentSoft = Color(hex: 0x4a2f16)
    static let onAccent = Color(hex: 0x161618)
    static let deckA = Color(hex: 0x4fa3ff)
    static let deckB = Color(hex: 0xc06a2b)
    static let match = Color(hex: 0x5fd37a)
    static let warn = Color(hex: 0xff5a4f)
    static let waveLow = Color(hex: 0x3d6fb3)
    static let waveMid = Color(hex: 0xa8b4c4)
    static let waveHigh = Color(hex: 0xeef2f7)

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
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xff) / 255,
                  green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255)
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
