//
//  Stack.swift
//  Spindle
//
//  The Mix page's stack: your set as an endless queue. Decks A and B hold
//  the cards being played; "Up next" is the queue. Next ▸ on a deck sends
//  its card to Played and loads the first queued card onto that turntable.
//  The queue is remembered between launches.
//

import Foundation
import Observation
import SwiftUI

nonisolated struct StackItem: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var path: String
    var url: URL { URL(fileURLWithPath: path) }

    static let key = "mix.stack"

    static func load() -> [StackItem] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let items = try? JSONDecoder().decode([StackItem].self, from: data) else { return [] }
        return items
    }

    static func save(_ items: [StackItem]) {
        if let data = try? JSONEncoder().encode(items) { UserDefaults.standard.set(data, forKey: key) }
    }
}

extension AppModel {
    /// Adds tracks to the queue (at the end, or at a position).
    func addToStack(_ urls: [URL], at index: Int? = nil) {
        let files = PlaylistStore.audioFiles(in: urls)
        let items = files.map { StackItem(path: $0.path) }
        let at = min(max(index ?? stack.count, 0), stack.count)
        stack.insert(contentsOf: items, at: at)
        fillEmptyDecks()
        // Tracks from outside the library still get analysed and prepped.
        let unknown = files.filter { analysis.analysis(for: $0) == nil }
        if !unknown.isEmpty {
            Task {
                await analysis.analyze(unknown)
                await prepareAll()
            }
        }
    }

    /// Puts tracks at the top of the queue.
    func playNext(_ urls: [URL]) { addToStack(urls, at: 0) }

    func moveInStack(from offsets: IndexSet, to destination: Int) {
        stack.move(fromOffsets: offsets, toOffset: destination)
    }

    func removeFromStack(_ id: UUID) {
        stack.removeAll { $0.id == id }
    }

    func clearStack() { stack.removeAll() }

    /// Sends a queued card to a turntable now. The card that was there goes
    /// back to the top of the queue, so nothing is lost (a swap).
    func sendToDeck(_ item: StackItem, deck: DeckModel) {
        stack.removeAll { $0.id == item.id }
        if let current = deckCards[deck.id], current.id != item.id {
            stack.insert(current, at: 0)
        }
        deckCards[deck.id] = item
        Task { await load(url: item.url, into: deck, fromStack: true) }
    }

    /// Done with this deck's track: it goes to Played and the next queued
    /// card loads onto this turntable.
    func next(deck: DeckModel) {
        if let current = deckCards[deck.id] {
            played.insert(current, at: 0)
            deckCards[deck.id] = nil
        }
        if let first = stack.first {
            sendToDeck(first, deck: deck)
        }
    }

    /// Empty decks take the first queued cards.
    func fillEmptyDecks() {
        for deck in decks where deck.track == nil && deckCards[deck.id] == nil && !deck.loading {
            guard let first = stack.first else { return }
            sendToDeck(first, deck: deck)
        }
    }

    /// A track loaded some other way (Organize, Prep, a file) becomes the
    /// deck's card; the card it replaces goes to Played.
    func noteLoaded(_ url: URL, deck: DeckModel) {
        if deckCards[deck.id]?.path == url.path { return }
        if let old = deckCards[deck.id] { played.insert(old, at: 0) }
        deckCards[deck.id] = StackItem(path: url.path)
    }

    /// Default columns for the Mix track list.
    func defaultMixView() -> ViewSettings {
        var v = ViewSettings()
        v.hidden = Set(records.allFields).subtracting([.name, .bpm, .key, .energy, .tags])
        return v
    }

    func mixView(for tab: String) -> ViewSettings {
        mixTabViews[tab] ?? defaultMixView()
    }
}
