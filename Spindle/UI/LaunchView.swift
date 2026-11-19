//
//  LaunchView.swift
//  Spindle
//
//  The Launch page (option A): a clip launcher for DJing, next to Mix.
//  Master clock on top, six channels × eight scenes, channel strips, and a
//  browser to drag tracks from. Clips start on the next beat, bar or four
//  bars, in phase with each other.
//

import SwiftUI

struct LaunchView: View {
    let model: AppModel
    @Bindable var launch: LaunchModel

    var body: some View {
        VStack(spacing: 0) {
            MasterBar(model: model, launch: launch)
            Rectangle().fill(Theme.line).frame(height: 1)
            HStack(spacing: 1) {
                VStack(spacing: 0) {
                    ChannelHeaders(launch: launch)
                    Rectangle().fill(Theme.line).frame(height: 1)
                    ScrollView {
                        VStack(spacing: 4) {
                            ForEach(0..<LaunchSet.rows, id: \.self) { row in
                                HStack(spacing: 4) {
                                    ForEach(0..<LaunchSet.columns, id: \.self) { column in
                                        LaunchCell(model: model, row: row, column: column)
                                    }
                                    Button { model.launchScene(row) } label: {
                                        HStack(spacing: 4) {
                                            Image(systemName: "play.fill").font(.system(size: 9))
                                            Text(launch.set.scenes[row]).font(Theme.caption).lineLimit(1)
                                        }
                                        .foregroundStyle(Theme.ink)
                                        .frame(width: 96, height: 62)
                                        .background(Theme.panelRaised)
                                        .overlay(RoundedRectangle(cornerRadius: Theme.radiusMd).stroke(Theme.line, lineWidth: 1))
                                        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusMd))
                                    }
                                    .buttonStyle(.plain)
                                    .help("Start every clip in this row together; channels with no clip here stop")
                                }
                            }
                        }
                        .padding(6)
                    }
                    Rectangle().fill(Theme.line).frame(height: 1)
                    ChannelStrips(model: model, launch: launch)
                }
                .background(Theme.bg)
                LaunchBrowser(model: model, library: model.library)
                    .frame(width: 300)
            }
            .background(Theme.line)
        }
        .background(Theme.bg)
        .overlay {
            if model.engine == nil {
                Text("Start the audio engine to play clips.").font(Theme.body).foregroundStyle(Theme.inkMuted)
                    .padding(Theme.space3).background(Theme.panelRaised)
            }
        }
    }
}

// MARK: Master bar

private struct MasterBar: View {
    let model: AppModel
    @Bindable var launch: LaunchModel

    var body: some View {
        HStack(spacing: Theme.space3) {
            LabelText("Master")
            TimelineView(.periodic(from: .now, by: 0.05)) { _ in
                let bpm = model.masterBPM
                let beat = model.engine?.masterBeat ?? 0
                let bar = Int(beat / 4) + 1, inBar = Int(beat) % 4
                HStack(spacing: Theme.space3) {
                    Text(String(format: "%.2f", bpm)).font(Theme.readout).foregroundStyle(Theme.ink).frame(width: 64, alignment: .trailing)
                    Text(String(format: "%d.%d", bar, inBar + 1)).font(Theme.readout).foregroundStyle(Theme.ink).frame(width: 64, alignment: .leading)
                    HStack(spacing: 4) {
                        ForEach(0..<4, id: \.self) { i in
                            Rectangle().fill(i <= inBar ? Theme.accent : Theme.control).frame(width: 8, height: 8)
                        }
                    }
                }
            }
            Picker("Tempo", selection: $launch.tempoSource) {
                ForEach(TempoSource.allCases) { Text($0.rawValue).tag($0) }
            }
            .frame(width: 170)
            .help("Manual, or follow a deck's tempo")
            if launch.tempoSource == .manual {
                HStack(spacing: 2) {
                    Button("−") { launch.manualBPM = max(60, (launch.manualBPM - 1).rounded()) }
                    Button("−0.1") { launch.manualBPM = max(60, launch.manualBPM - 0.1) }
                    Button("+0.1") { launch.manualBPM = min(200, launch.manualBPM + 0.1) }
                    Button("+") { launch.manualBPM = min(200, (launch.manualBPM + 1).rounded()) }
                }
                .buttonStyle(FlatButtonStyle())
            }
            Picker("Launch", selection: $launch.quantize) {
                Text("1 beat").tag(1)
                Text("1 bar").tag(4)
                Text("4 bars").tag(16)
            }
            .pickerStyle(.segmented)
            .frame(width: 200)
            if let error = launch.error {
                Text(error).font(Theme.caption).foregroundStyle(Theme.warn).lineLimit(1)
                    .onTapGesture { launch.error = nil }
            }
            Spacer()
            Text(model.engine.map { $0.clipOutput == 4 ? "Out 5–6 (AUX)" : "Out 1–2" } ?? "")
                .font(Theme.caption).foregroundStyle(Theme.inkFaint)
            Button("Stop all") { model.stopAllClips() }.buttonStyle(FlatButtonStyle())
        }
        .font(Theme.caption)
        .foregroundStyle(Theme.inkMuted)
        .padding(.horizontal, Theme.space3)
        .frame(height: 40)
        .background(Theme.panel)
    }
}

// MARK: Grid

private struct ChannelHeaders: View {
    let launch: LaunchModel
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<LaunchSet.columns, id: \.self) { c in
                HStack(spacing: 6) {
                    Text("\(c + 1)").font(Theme.readoutSm).foregroundStyle(Theme.inkMuted)
                    LabelText(launch.set.channels[c], color: Theme.ink)
                    Spacer()
                }
                .padding(.horizontal, Theme.space2)
                .frame(maxWidth: .infinity, minHeight: 30)
                .background(Theme.panelRaised)
            }
            LabelText("Scenes").frame(width: 96, alignment: .leading).padding(.leading, Theme.space2)
        }
        .padding(.horizontal, 6)
        .background(Theme.panelRaised)
    }
}

private struct LaunchCell: View {
    let model: AppModel
    let row: Int
    let column: Int
    @State private var dropTargeted = false

    var body: some View {
        let clip = model.launch.set.clip(row, column)
        Group {
            if let clip {
                TimelineView(.periodic(from: .now, by: 0.05)) { _ in
                    let t = model.engine?.clipPlayers[column].telemetry.pointee ?? ClipTelemetry()
                    clipBody(clip, playing: t.clipID == clip.id, queued: t.pendingID == clip.id,
                             progress: t.clipID == clip.id ? t.progress : 0)
                }
                .contentShape(Rectangle())
                .onTapGesture { model.toggleClip(row: row, column: column) }
                .contextMenu { menu(clip) }
            } else {
                RoundedRectangle(cornerRadius: Theme.radiusMd)
                    .stroke(dropTargeted ? Theme.accent : Theme.line, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .frame(maxWidth: .infinity, minHeight: 62, maxHeight: 62)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 62, maxHeight: 62)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = PlaylistStore.audioFiles(in: urls).first else { return false }
            model.assignClip(url, row: row, column: column)
            return true
        } isTargeted: { dropTargeted = $0 }
    }

    private func clipBody(_ clip: LaunchClip, playing: Bool, queued: Bool, progress: Double) -> some View {
        let a = model.analysis.analysis(for: clip.url)
        let timing = model.clipTiming(clip)
        let rate = model.masterBPM / timing.bpm
        let loading = model.launch.loading.contains(clip.id)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Rectangle().fill(clip.start.role?.color ?? Theme.inkMuted).frame(width: 7, height: 7)
                Text(clip.name).font(Theme.caption).foregroundStyle(Theme.ink).lineLimit(1)
                Spacer(minLength: 0)
                if matchesDecks(a) { Circle().fill(Theme.match).frame(width: 6, height: 6) }
            }
            HStack(spacing: 6) {
                Text(clip.part).font(Theme.readoutSm).foregroundStyle(Theme.inkMuted).lineLimit(1)
                Spacer(minLength: 0)
                Text(loading ? "LOADING" : queued ? "NEXT" : String(format: "%.0f", timing.bpm))
                    .font(Theme.readoutSm)
                    .foregroundStyle(queued ? Theme.ink : (abs(rate - 1) > 0.06 ? Theme.warn : Theme.inkFaint))
                    .help(abs(rate - 1) > 0.06 ? String(format: "Plays %+.0f%% faster or slower than recorded (pitch changes too)", (rate - 1) * 100) : "Clip tempo")
            }
            HStack(spacing: 6) {
                KeyChip(analysis: a, showMood: false)
                Spacer(minLength: 0)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Theme.control)
                    Rectangle().fill(Color(hex: 0x6ad19b)).frame(width: geo.size.width * progress)
                }
            }
            .frame(height: 2)
        }
        .padding(.horizontal, 7).padding(.vertical, 5)
        .frame(maxWidth: .infinity, minHeight: 62, maxHeight: 62, alignment: .topLeading)
        .background(playing ? Color(hex: 0x24302a) : Theme.panelRaised)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radiusMd)
                .stroke(playing ? Color(hex: 0x6ad19b) : (queued ? Theme.inkMuted : Color.clear),
                        style: StrokeStyle(lineWidth: 1, dash: queued ? [4, 3] : []))
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusMd))
    }

    private func matchesDecks(_ a: TrackAnalysis?) -> Bool {
        guard let a else { return false }
        return model.decks.contains { deck in
            deck.playing && deck.track.flatMap { model.analysis.analysis(for: $0.url) }.map { Compatibility.keys($0, a) } == true
        }
    }

    @ViewBuilder
    private func menu(_ clip: LaunchClip) -> some View {
        let prep = model.prep.prep(for: clip.url)
        Menu("Start at") {
            ForEach(ClipStart.allCases) { s in
                Button { model.editClip(row: row, column: column) { $0.start = s } } label: {
                    Label(s == .start ? "First bar" : "\(s.rawValue) cue", systemImage: clip.start == s ? "checkmark" : "")
                }
                .disabled(s.role != nil && prep?.cue(s.role!) == nil)
            }
        }
        Menu("Length") {
            ForEach([1, 2, 4, 8, 16, 32], id: \.self) { bars in
                Button { model.editClip(row: row, column: column) { $0.bars = bars } } label: {
                    Label("\(bars) bar\(bars == 1 ? "" : "s"), looped", systemImage: clip.bars == bars ? "checkmark" : "")
                }
            }
            Divider()
            Button { model.editClip(row: row, column: column) { $0.bars = 0 } } label: {
                Label("To the end, once", systemImage: clip.bars == 0 ? "checkmark" : "")
            }
        }
        Divider()
        ForEach(model.decks) { deck in
            Button("Load whole track on deck \(deck.label)") { Task { await model.load(url: clip.url, into: deck) } }
        }
        Divider()
        Button("Remove clip", role: .destructive) { model.removeClip(row: row, column: column) }
    }
}

// MARK: Channel strips

private struct ChannelStrips: View {
    let model: AppModel
    @Bindable var launch: LaunchModel

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<LaunchSet.columns, id: \.self) { c in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        LabelText("Vol")
                        Slider(value: Binding(get: { launch.volumes[c] }, set: { model.setChannelVolume($0, c) }), in: 0...1)
                            .controlSize(.mini)
                    }
                    HStack(spacing: 6) {
                        LabelText("Flt")
                        Slider(value: Binding(get: { launch.filters[c] }, set: { model.setChannelFilter(abs($0) < 0.03 ? 0 : $0, c) }), in: -1...1)
                            .controlSize(.mini)
                    }
                    HStack(spacing: 4) {
                        Button { model.setChannelMute(!launch.muted[c], c) } label: {
                            Text("M").font(Theme.label).frame(width: 22, height: 18)
                                .foregroundStyle(launch.muted[c] ? Theme.onAccent : Theme.ink)
                                .background(launch.muted[c] ? Theme.warn : Theme.control)
                                .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSm))
                        }
                        .buttonStyle(.plain)
                        .help("Mute")
                        Button { model.stopChannel(c) } label: {
                            Text("■").font(Theme.label).frame(width: 22, height: 18)
                                .foregroundStyle(Theme.ink).background(Theme.control)
                                .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSm))
                        }
                        .buttonStyle(.plain)
                        .help("Stop this channel on the next launch point")
                        Spacer()
                        TimelineView(.periodic(from: .now, by: 0.05)) { _ in
                            SignalMeter(level: model.engine?.clipPlayers[c].telemetry.pointee.level ?? 0)
                                .frame(width: 50, height: 4)
                        }
                    }
                }
                .padding(.horizontal, Theme.space2)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .background(Theme.panel)
            }
            Color.clear.frame(width: 96, height: 1)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .fixedSize(horizontal: false, vertical: true)
        .tint(Theme.inkMuted)
        .background(Theme.panel)
    }
}

// MARK: Browser

private struct LaunchBrowser: View {
    let model: AppModel
    @Bindable var library: LibraryModel
    @State private var source = "all"
    @State private var search = ""

    private var tracks: [LibraryTrack] {
        let base = source == "all" ? library.allTracks : UUID(uuidString: source).map(library.tracks(inPlaylist:)) ?? []
        return search.isEmpty ? base : base.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.space2) {
                LabelText("Browser", color: Theme.ink)
                Spacer()
                Picker("", selection: $source) {
                    Text("All tracks").tag("all")
                    ForEach(library.playlists.playlists, id: \.node.id) { Text($0.path).tag($0.node.id.uuidString) }
                }
                .labelsHidden()
                .frame(width: 150)
            }
            .padding(.horizontal, Theme.space3)
            .frame(height: 36)
            .background(Theme.panelRaised)
            TextField("Search", text: $search)
                .textFieldStyle(.roundedBorder)
                .padding(Theme.space2)
            Rectangle().fill(Theme.line).frame(height: 1)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(tracks) { track in
                        let a = model.analysis.analysis(for: track.url)
                        HStack(spacing: Theme.space2) {
                            Text(track.name).font(Theme.caption).foregroundStyle(Theme.ink).lineLimit(1)
                            Spacer(minLength: 0)
                            Text(a.map { String(format: "%.0f", model.prep.prep(for: track.url)?.bpm ?? $0.bpm) } ?? "—")
                                .font(Theme.readoutSm).foregroundStyle(Theme.inkMuted)
                            KeyChip(analysis: a, showMood: false)
                        }
                        .padding(.horizontal, Theme.space3)
                        .frame(height: 30)
                        .contentShape(Rectangle())
                        .draggable(track.url)
                        .help("Drag onto a cell to make a clip")
                        Rectangle().fill(Theme.panelRaised).frame(height: 1)
                    }
                }
            }
            Text("Drag a track onto a cell: 8 bars from its DROP, looped. Right-click a clip to change start and length. Click to start on the next launch point; click again to stop.")
                .font(Theme.caption).foregroundStyle(Theme.inkFaint)
                .padding(Theme.space3)
        }
        .background(Theme.panel)
    }
}
