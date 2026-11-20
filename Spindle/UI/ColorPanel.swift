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

    var body: some View {
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
            deckRow("A", selection: $look.deckAColor)
            deckRow("B", selection: $look.deckBColor)
            Text("Waveforms, deck headers and whatever is active on a deck.")
                .font(Theme.caption).foregroundStyle(Theme.inkFaint)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(Theme.space3)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.panel)
    }

    private func deckRow(_ label: String, selection: Binding<DeckColor>) -> some View {
        HStack(alignment: .top, spacing: Theme.space2) {
            Text(label).font(Theme.label).foregroundStyle(selection.wrappedValue.color).frame(width: 12)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(22), spacing: 6), count: 5), spacing: 6) {
                ForEach(DeckColor.allCases) { c in
                    let on = selection.wrappedValue == c
                    Button { selection.wrappedValue = c } label: {
                        RoundedRectangle(cornerRadius: Theme.radiusSm)
                            .fill(c.color)
                            .frame(width: 22, height: 22)
                            .overlay(RoundedRectangle(cornerRadius: Theme.radiusSm + 2)
                                .stroke(on ? Theme.ink : Color.clear, lineWidth: 2)
                                .padding(-3))
                    }
                    .buttonStyle(.plain)
                    .help("Deck \(label): \(c.rawValue)")
                }
            }
        }
    }
}
