//
//  KeyDisplay.swift
//  Spindle
//
//  Musical keys without the music theory. Every key sits on a wheel of 12
//  colours (the Camelot wheel underneath): tracks with the same or
//  neighbouring colours mix smoothly. Each key is also Dark (minor: moody,
//  serious) or Bright (major: uplifting, happy).
//

import SwiftUI

enum KeyStyle {
    /// One hue per wheel position, so neighbours look alike. Dark keys are
    /// drawn deeper, bright keys lighter.
    static func color(number: Int, minor: Bool) -> Color {
        let hue = Double((number - 1 + 12) % 12) / 12
        return Color(hue: hue, saturation: minor ? 0.62 : 0.45, brightness: minor ? 0.72 : 0.95)
    }

    static func color(_ a: TrackAnalysis) -> Color { color(number: a.camelotNumber, minor: a.keyMinor) }

    static func mood(minor: Bool) -> String { minor ? "Dark" : "Bright" }

    static let explanation = """
        Key colour: tracks with the same colour, or the colour next to it on \
        the wheel, sound good together. Dark = minor key (moody), Bright = \
        major key (uplifting).
        """
}

/// A key as a coloured dot, its wheel number and its mood: "● 8 Dark".
struct KeyChip: View {
    let analysis: TrackAnalysis?
    var showMood = true

    var body: some View {
        if let a = analysis {
            HStack(spacing: 4) {
                Circle()
                    .fill(KeyStyle.color(a))
                    .frame(width: 9, height: 9)
                Text("\(a.camelotNumber)")
                    .font(Theme.readoutSm)
                    .foregroundStyle(Theme.ink)
                    .frame(minWidth: 14, alignment: .leading)
                if showMood {
                    Text(KeyStyle.mood(minor: a.keyMinor))
                        .font(Theme.caption)
                        .foregroundStyle(Theme.inkMuted)
                }
            }
            .opacity(a.keyConfidence < 0.02 ? 0.55 : 1)
            .help("Key \(a.camelotNumber) \(KeyStyle.mood(minor: a.keyMinor)) (\(a.keyName), Camelot \(a.camelot))\(a.keyConfidence < 0.02 ? " — unsure" : "")\n\n\(KeyStyle.explanation)")
        } else {
            Text("—").font(Theme.readoutSm).foregroundStyle(Theme.inkFaint)
        }
    }
}

/// How a track would follow another, in plain words.
enum MixRelation: Int, CaseIterable, Identifiable {
    case sameKey, lift, drop, moodSwap
    var id: Int { rawValue }

    var title: String {
        switch self {
        case .sameKey: "Same key"
        case .lift: "Lift"
        case .drop: "Drop"
        case .moodSwap: "Mood change"
        }
    }

    var explanation: String {
        switch self {
        case .sameKey: "Smoothest blend: the same colour."
        case .lift: "One colour up the wheel: raises the energy."
        case .drop: "One colour down the wheel: calms it a little."
        case .moodSwap: "Same number, Dark ↔ Bright: changes the mood."
        }
    }

    /// The relation from `a` (playing) to `b` (next), if they mix.
    static func between(_ a: TrackAnalysis, _ b: TrackAnalysis) -> MixRelation? {
        let na = a.camelotNumber, nb = b.camelotNumber
        if na == nb { return a.keyMinor == b.keyMinor ? .sameKey : .moodSwap }
        guard a.keyMinor == b.keyMinor else { return nil }
        if (na % 12) + 1 == nb { return .lift }
        if (nb % 12) + 1 == na { return .drop }
        return nil
    }
}
