//
//  ColorPanel.swift
//  Spindle
//
//  Everything about colour in one panel on the right, opened and closed
//  with the button at the right of the top bar: the theme, the waveform
//  style, the 3-Band palette and each deck's colour. Changes apply at once
//  and are remembered.
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
        .help(look.panelOpen ? "Close the colour panel" : "Colours: theme, waveform, deck colours")
    }
}

struct ColorPanel: View {
    @Bindable var look: LookSettings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.space4) {
                HStack {
                    LabelText("Colours")
                    Spacer()
                    Button { withAnimation(.easeOut(duration: 0.15)) { look.panelOpen = false } } label: {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.inkMuted)
                    .help("Close")
                }

                section("Theme") {
                    ForEach(AppTheme.allCases) { theme in
                        option(theme.rawValue, detail: theme.summary, on: look.theme == theme) { look.theme = theme }
                    }
                }

                section("Waveform") {
                    Picker("", selection: $look.waveStyle) {
                        ForEach(WaveStyle.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                section("Deck colours") {
                    deckRow("A", selection: $look.deckAColor)
                    deckRow("B", selection: $look.deckBColor)
                    Text("Mono waveforms, deck headers and whatever is active on a deck. Colours you pick here stay in every theme.")
                        .font(Theme.caption).foregroundStyle(Theme.inkFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }

                section("3-Band colours") {
                    ForEach(BandPalette.allCases) { p in
                        Button { look.bandPalette = p } label: {
                            HStack(spacing: Theme.space2) {
                                HStack(spacing: 0) {
                                    Rectangle().fill(Color(hex: p.hex.low, exact: true))
                                    Rectangle().fill(Color(hex: p.hex.mid, exact: true))
                                    Rectangle().fill(Color(hex: p.hex.high, exact: true))
                                }
                                .frame(width: 36, height: 14)
                                .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSm))
                                Text(p.rawValue).font(Theme.body)
                                    .foregroundStyle(look.bandPalette == p ? Theme.ink : Theme.inkMuted)
                                Spacer(minLength: 0)
                                if look.bandPalette == p { Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)) }
                            }
                            .padding(.vertical, 3)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.ink)
                        .help(p.summary)
                    }
                }
            }
            .padding(Theme.space3)
        }
        .frame(maxHeight: .infinity)
        .background(Theme.panel)
    }

    private func section<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: Theme.space2) {
            LabelText(title)
            content()
        }
    }

    private func option(_ name: String, detail: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Theme.space2) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(Theme.body).foregroundStyle(on ? Theme.ink : Theme.inkMuted)
                    Text(detail).font(Theme.caption).foregroundStyle(Theme.inkFaint)
                }
                Spacer(minLength: 0)
                if on { Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.ink) }
            }
            .padding(.horizontal, Theme.space2).padding(.vertical, 5)
            .background(on ? Theme.panelRaised : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusMd))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
