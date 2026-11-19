//
//  OrganizeView.swift
//  Spindle
//
//  Page 1, Organize: find tracks that work together. Crates on the left, a
//  sortable table of the analysis, and a key × energy map. Selecting a track
//  rings the tracks that mix well with it (compatible Camelot key and energy
//  within one step).
//

import SwiftUI

struct OrganizeRow: Identifiable {
    let track: LibraryTrack
    let analysis: TrackAnalysis?
    var id: URL { track.url }
    var name: String { track.name }
    var crate: String { track.crate }
    var bpm: Double { analysis?.bpm ?? 0 }
    var keySort: Int { analysis.map { $0.camelotNumber * 2 + ($0.keyMinor ? 0 : 1) } ?? 99 }
    var energy: Int { analysis?.energy ?? 0 }
    var intro: String { analysis?.intro.rawValue ?? "" }
    var outro: String { analysis?.outro.rawValue ?? "" }
    var duration: Double { analysis?.duration ?? 0 }
}

enum Compatibility {
    /// Camelot-compatible: same code, ±1 on the wheel with the same letter, or
    /// the relative key (same number, other letter).
    static func keys(_ a: TrackAnalysis, _ b: TrackAnalysis) -> Bool {
        let na = a.camelotNumber, nb = b.camelotNumber
        if na == nb { return true }
        let step = (na - nb + 12) % 12
        return a.keyMinor == b.keyMinor && (step == 1 || step == 11)
    }

    static func mixes(_ a: TrackAnalysis, _ b: TrackAnalysis) -> Bool {
        keys(a, b) && abs(a.energy - b.energy) <= 1 && abs(a.bpm - b.bpm) / a.bpm < 0.08
    }
}

struct OrganizeView: View {
    @Bindable var library: LibraryModel
    let analysis: AnalysisStore
    let model: AppModel
    @State private var selection: URL?
    @State private var sortOrder = [KeyPathComparator(\OrganizeRow.keySort)]

    private var rows: [OrganizeRow] {
        library.visibleTracks
            .map { OrganizeRow(track: $0, analysis: analysis.analysis(for: $0.url)) }
            .sorted(using: sortOrder)
    }

    private var selectedAnalysis: TrackAnalysis? {
        selection.flatMap { analysis.analysis(for: $0) }
    }

    var body: some View {
        HStack(spacing: 1) {
            CrateList(library: library, model: model)
                .frame(width: 180)
            VStack(spacing: 1) {
                toolbar
                table
                    .frame(minHeight: 200)
                selectionBar
            }
            KeyEnergyMap(rows: rows, selection: $selection)
                .frame(minWidth: 380, idealWidth: 460)
        }
        .background(Theme.line)
    }

    private var toolbar: some View {
        HStack(spacing: Theme.space3) {
            LabelText(library.crate ?? "All tracks")
            if analysis.pending > 0 {
                Text("Analysing… \(analysis.pending) left")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.inkMuted)
            }
            Spacer()
            TextField("Search", text: $library.search)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 240)
        }
        .padding(.horizontal, Theme.space3)
        .padding(.vertical, Theme.space2)
        .background(Theme.panelRaised)
    }

    private var table: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Track", value: \.name) { row in
                HStack(spacing: Theme.space1) {
                    if let a = selectedAnalysis, let b = row.analysis, row.id != selection, Compatibility.mixes(a, b) {
                        Circle().fill(Theme.match).frame(width: 6, height: 6)
                    }
                    Text(row.name).lineLimit(1)
                }
            }
            .width(min: 180, ideal: 320)
            TableColumn("Crate", value: \.crate) { Text($0.crate).foregroundStyle(Theme.inkMuted) }
                .width(min: 60, ideal: 90)
            TableColumn("BPM", value: \.bpm) { row in
                Text(row.analysis == nil ? "—" : String(format: "%.1f", row.bpm)).font(Theme.readoutSm)
            }
            .width(56)
            TableColumn("Key", value: \.keySort) { row in
                if let a = row.analysis {
                    Text(a.camelot)
                        .font(Theme.readoutSm)
                        .foregroundStyle(a.keyConfidence < 0.02 ? Theme.inkFaint : Theme.ink)
                        .help("\(a.keyName)\(a.keyConfidence < 0.02 ? " (uncertain)" : "")")
                } else { Text("—").font(Theme.readoutSm) }
            }
            .width(44)
            TableColumn("Energy", value: \.energy) { row in
                EnergyBar(energy: row.energy)
            }
            .width(70)
            TableColumn("Intro", value: \.intro) { Text($0.intro).foregroundStyle(Theme.inkMuted) }
                .width(70)
            TableColumn("Outro", value: \.outro) { Text($0.outro).foregroundStyle(Theme.inkMuted) }
                .width(70)
            TableColumn("Length", value: \.duration) { row in
                Text(row.analysis == nil ? "—" : Self.length(row.duration)).font(Theme.readoutSm)
            }
            .width(52)
        }
        .font(Theme.body)
        .contextMenu(forSelectionType: URL.self) { urls in
            if let url = urls.first {
                Button("Load into deck A") { Task { await model.load(url: url, into: model.decks[0]) } }
                Button("Load into deck B") { Task { await model.load(url: url, into: model.decks[1]) } }
            }
        } primaryAction: { urls in
            if let url = urls.first { Task { await model.load(url: url, into: model.decks[0]) } }
        }
    }

    @ViewBuilder
    private var selectionBar: some View {
        HStack(spacing: Theme.space3) {
            if let url = selection, let track = library.tracks.first(where: { $0.url == url }) {
                Text(track.name).font(Theme.body).foregroundStyle(Theme.ink).lineLimit(1)
                if let a = analysis.analysis(for: url) {
                    Text("\(String(format: "%.1f", a.bpm)) BPM · \(a.camelot) (\(a.keyName)) · E\(a.energy)")
                        .font(Theme.readoutSm).foregroundStyle(Theme.inkMuted)
                    let matches = rows.filter { $0.id != url && $0.analysis.map { Compatibility.mixes(a, $0) } == true }.count
                    Text("\(matches) tracks mix well").font(Theme.caption).foregroundStyle(Theme.match)
                }
                Spacer()
                ForEach(model.decks) { deck in
                    Button("Load \(deck.label)") { Task { await model.load(url: url, into: deck) } }
                        .buttonStyle(FlatButtonStyle())
                }
            } else {
                Text("Select a track to see what mixes with it. Double-click loads into deck A.")
                    .font(Theme.caption).foregroundStyle(Theme.inkFaint)
                Spacer()
            }
        }
        .padding(.horizontal, Theme.space3)
        .frame(height: 40)
        .background(Theme.panelRaised)
    }

    static func length(_ seconds: Double) -> String {
        String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }
}

struct EnergyBar: View {
    let energy: Int
    var body: some View {
        HStack(spacing: 1) {
            ForEach(1...10, id: \.self) { i in
                Rectangle()
                    .fill(i <= energy ? Theme.inkMuted : Theme.control)
                    .frame(width: 4, height: 10)
            }
        }
        .help(energy > 0 ? "E\(energy)" : "Not analysed yet")
    }
}

/// Camelot number (1–12) across, energy (1–10) up. Minor keys (A) are filled
/// dots, major keys (B) hollow. The selected track is accent; tracks that mix
/// with it are ringed.
struct KeyEnergyMap: View {
    let rows: [OrganizeRow]
    @Binding var selection: URL?
    @State private var hovered: OrganizeRow?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                LabelText("Key × energy")
                Spacer()
                Text(hovered.map { "\($0.name) · \($0.analysis?.camelot ?? "") · E\($0.energy)" } ?? "● minor (A)   ○ major (B)")
                    .font(Theme.caption).foregroundStyle(Theme.inkMuted).lineLimit(1)
            }
            .padding(.horizontal, Theme.space3)
            .frame(height: 36)
            .background(Theme.panelRaised)
            GeometryReader { geo in
                let plot = CGRect(x: 28, y: 8, width: geo.size.width - 40, height: geo.size.height - 32)
                ZStack(alignment: .topLeading) {
                    Canvas { context, _ in draw(context, plot) }
                    // Hit targets for hover and selection.
                    ForEach(placed(in: plot), id: \.row.id) { item in
                        Circle()
                            .fill(Color.clear)
                            .contentShape(Circle())
                            .frame(width: 14, height: 14)
                            .position(item.point)
                            .onHover { inside in hovered = inside ? item.row : (hovered?.id == item.row.id ? nil : hovered) }
                            .onTapGesture { selection = item.row.id }
                    }
                }
            }
            .background(Theme.panel)
        }
    }

    private struct Placed { let row: OrganizeRow; let point: CGPoint }

    private func placed(in plot: CGRect) -> [Placed] {
        // Spread tracks sharing a cell so every dot stays visible.
        var cellCount: [String: Int] = [:]
        return rows.compactMap { row in
            guard let a = row.analysis else { return nil }
            let cell = "\(a.camelotNumber)\(a.keyMinor)\(a.energy)"
            let n = cellCount[cell, default: 0]
            cellCount[cell] = n + 1
            let colW = plot.width / 12, rowH = plot.height / 10
            let half = colW / 2
            let x = plot.minX + CGFloat(a.camelotNumber - 1) * colW + (a.keyMinor ? half * 0.5 : half * 1.5)
            let y = plot.maxY - (CGFloat(a.energy) - 0.5) * rowH
            let jitter = CGFloat(n) * 5
            return Placed(row: row, point: CGPoint(x: x + (n % 2 == 0 ? jitter / 2 : -jitter / 2), y: y - CGFloat(n / 2) * 5))
        }
    }

    private func draw(_ context: GraphicsContext, _ plot: CGRect) {
        let colW = plot.width / 12, rowH = plot.height / 10
        var grid = Path()
        for c in 0...12 { grid.addRect(CGRect(x: plot.minX + CGFloat(c) * colW, y: plot.minY, width: 1, height: plot.height)) }
        for r in 0...10 { grid.addRect(CGRect(x: plot.minX, y: plot.minY + CGFloat(r) * rowH, width: plot.width, height: 1)) }
        context.fill(grid, with: .color(Theme.line.opacity(0.6)))
        for c in 1...12 {
            context.draw(Text("\(c)").font(Theme.readoutSm).foregroundStyle(Theme.inkFaint),
                         at: CGPoint(x: plot.minX + (CGFloat(c) - 0.5) * colW, y: plot.maxY + 12))
        }
        for e in [1, 5, 10] {
            context.draw(Text("E\(e)").font(Theme.readoutSm).foregroundStyle(Theme.inkFaint),
                         at: CGPoint(x: plot.minX - 14, y: plot.maxY - (CGFloat(e) - 0.5) * rowH))
        }
        let selectedAnalysis = rows.first { $0.id == selection }?.analysis
        for item in placed(in: plot) {
            guard let a = item.row.analysis else { continue }
            let rect = CGRect(x: item.point.x - 4, y: item.point.y - 4, width: 8, height: 8)
            let isSelected = item.row.id == selection
            let mixes = selectedAnalysis.map { !isSelected && Compatibility.mixes($0, a) } ?? false
            let color = isSelected ? Theme.accent : (selectedAnalysis == nil || mixes ? Theme.ink : Theme.inkFaint)
            if a.keyMinor {
                context.fill(Path(ellipseIn: rect), with: .color(color))
            } else {
                context.stroke(Path(ellipseIn: rect), with: .color(color), lineWidth: 1.5)
            }
            if mixes {
                context.stroke(Path(ellipseIn: rect.insetBy(dx: -3, dy: -3)), with: .color(Theme.match), lineWidth: 1.5)
            }
        }
    }
}

/// Crates shared by the Organize and Mix pages.
struct CrateList: View {
    @Bindable var library: LibraryModel
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LabelText("Crates")
                .padding(.horizontal, Theme.space3)
                .padding(.vertical, Theme.space2)
            row(nil, title: "All tracks", count: library.tracks.count)
            ForEach(library.crates, id: \.self) { crate in
                row(crate, title: crate, count: library.tracks.filter { $0.crate == crate }.count)
            }
            Spacer(minLength: 0)
            Button("Choose folder…") {
                Task {
                    await library.chooseFolder()
                    await model.analysis.analyze(library.tracks.map(\.url))
                }
            }
            .buttonStyle(FlatButtonStyle())
            .padding(Theme.space2)
        }
        .frame(maxHeight: .infinity)
        .background(Theme.panel)
    }

    private func row(_ crate: String?, title: String, count: Int) -> some View {
        let selected = library.crate == crate
        return Button {
            library.crate = crate
        } label: {
            HStack {
                Text(title).font(Theme.body).lineLimit(1)
                Spacer()
                Text("\(count)").font(Theme.readoutSm)
            }
            .foregroundStyle(selected ? Theme.ink : Theme.inkMuted)
            .padding(.horizontal, Theme.space3)
            .padding(.vertical, 5)
            .background(selected ? Theme.accentSoft : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
