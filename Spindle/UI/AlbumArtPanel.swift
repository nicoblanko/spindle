//
//  AlbumArtPanel.swift
//  Spindle
//
//  Right side of Organize: the album art of the track you're listening to
//  (or the one selected), from the file's tags or a cover image in its
//  folder, with its title and artist underneath.
//

import AppKit
import AVFoundation
import SwiftUI

struct AlbumArtPanel: View {
    let model: AppModel
    @State private var art: NSImage?
    @State private var title = ""
    @State private var artist = ""

    /// Listening wins; otherwise a single selected track.
    private var url: URL? {
        let page = model.prepPage
        if page.playing || page.playWhenLoaded != nil, let u = page.selected { return u }
        if model.organizeSelection.count == 1 { return model.organizeSelection.first }
        return page.selected
    }

    var body: some View {
        let url = url
        VStack(alignment: .leading, spacing: Theme.space3) {
            ZStack {
                Rectangle().fill(Theme.panelRaised)
                if let art {
                    Image(nsImage: art).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "music.note").font(.system(size: 40, weight: .light)).foregroundStyle(Theme.inkFaint)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipped()
            if url != nil {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(Theme.title).foregroundStyle(Theme.ink).lineLimit(2)
                    if !artist.isEmpty { Text(artist).font(Theme.body).foregroundStyle(Theme.inkMuted).lineLimit(1) }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.space3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.panel)
        .task(id: url) {
            guard let url else { art = nil; title = ""; artist = ""; return }
            let info = await AlbumArt.load(url)
            art = info.image; title = info.title; artist = info.artist
        }
    }
}

enum AlbumArt {
    struct Info { var image: NSImage?; var title: String; var artist: String }
    private static var cache: [URL: Info] = [:]

    static func load(_ url: URL) async -> Info {
        if let hit = cache[url] { return hit }
        let asset = AVURLAsset(url: url)
        var info = Info(image: nil, title: url.deletingPathExtension().lastPathComponent, artist: "")
        var items = (try? await asset.load(.commonMetadata)) ?? []
        if items.isEmpty, let formats = try? await asset.load(.availableMetadataFormats) {
            for f in formats { items += (try? await asset.loadMetadata(for: f)) ?? [] }
        }
        for item in items {
            switch item.commonKey {
            case .commonKeyTitle?:
                if let v = try? await item.load(.stringValue), !v.isEmpty { info.title = v }
            case .commonKeyArtist?:
                if let v = try? await item.load(.stringValue) { info.artist = v }
            case .commonKeyArtwork?:
                if info.image == nil, let d = try? await item.load(.dataValue) { info.image = NSImage(data: d) }
            default: break
            }
        }
        if info.image == nil {
            // A cover image next to the file.
            let folder = url.deletingLastPathComponent()
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            if let name = names.first(where: {
                let l = $0.lowercased()
                return (l.hasPrefix("cover") || l.hasPrefix("folder") || l.hasPrefix("front")) &&
                    (l.hasSuffix(".jpg") || l.hasSuffix(".jpeg") || l.hasSuffix(".png"))
            }) {
                info.image = NSImage(contentsOf: folder.appendingPathComponent(name))
            }
        }
        cache[url] = info
        return info
    }
}
