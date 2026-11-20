//
//  ColorPanel.swift
//  Spindle
//
//  The colour panel on the right, opened and closed with the button at the
//  right of the top bar: each deck's colour. The rest of the app is black
//  and white; these colours mark deck A and B and what is active on them.
//

import SwiftUI

/// Opens and closes the colour panel.
struct ColorPanelButton: View {
    @Bindable var look: LookSettings

    var body: some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { look.panelOpen.toggle() }
        } label: {
            Image(systemName: "paintpalette")
                .font(.system(size: 13))
                .frame(width: 30, height: 26)
                .foregroundStyle(look.panelOpen ? Theme.onAccent : Theme.ink)
                .background(look.panelOpen ? Theme.ink : Theme.control)
                .clipShape(RoundedRectangle(cornerRadius: Theme.radiusMd))
        }
        .buttonStyle(.plain)
        .help(look.panelOpen ? "Close the colour panel" : "Deck colours")
    }
}

struct ColorPanel: View {
    @Bindable var look: LookSettings
    /// Which deck the swatches colour.
    @State private var deck = 0

    private var selection: Binding<DeckColor> {
        deck == 0 ? $look.deckAColor : $look.deckBColor
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.space3) {
                HStack {
                    LabelText("Deck colours")
                    Spacer()
                    Button { withAnimation(.easeOut(duration: 0.15)) { look.panelOpen = false } } label: {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.inkMuted)
                    .help("Close")
                }
                // A | B, each showing its colour.
                VStack(spacing: 4) {
                    deckTab(0, "A", look.deckAColor)
                    deckTab(1, "B", look.deckBColor)
                }
                ForEach(DeckColor.Group.allCases) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(group.rawValue).font(Theme.caption).foregroundStyle(Theme.inkFaint)
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(22), spacing: 7), count: 6), alignment: .leading, spacing: 7) {
                            ForEach(group.colors) { swatch($0) }
                        }
                    }
                }
                Text("Waveforms, deck headers and whatever is active on a deck.")
                    .font(Theme.caption).foregroundStyle(Theme.inkFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Theme.space3)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.panel)
    }

    private func deckTab(_ index: Int, _ label: String, _ color: DeckColor) -> some View {
        let on = deck == index
        return Button { deck = index } label: {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: Theme.radiusSm).fill(color.color).frame(width: 12, height: 12)
                Text("Deck \(label)").font(Theme.body).lineLimit(1)
                Spacer(minLength: 0)
                Text(color.rawValue).font(Theme.caption).foregroundStyle(Theme.inkFaint).lineLimit(1)
            }
            .foregroundStyle(on ? Theme.ink : Theme.inkMuted)
            .padding(.horizontal, 8).frame(height: 28)
            .background(on ? Theme.panelRaised : Color.clear)
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusMd).stroke(on ? Theme.line : Color.clear, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusMd))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func swatch(_ c: DeckColor) -> some View {
        let on = selection.wrappedValue == c
        return Button { selection.wrappedValue = c } label: {
            RoundedRectangle(cornerRadius: Theme.radiusSm)
                .fill(c.color)
                .frame(width: 22, height: 22)
                .overlay(RoundedRectangle(cornerRadius: Theme.radiusSm + 2)
                    .stroke(on ? Theme.ink : Color.clear, lineWidth: 2)
                    .padding(-3))
        }
        .buttonStyle(.plain)
        .help("Deck \(deck == 0 ? "A" : "B"): \(c.rawValue)")
    }
}
