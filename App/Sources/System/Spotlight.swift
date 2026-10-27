import AppIntents
import CoreSpotlight
import Foundation
import PiUI

// Spotlight (spec "Apple integrations": index conversations and surfaces via `IndexedEntity`). Conversations are
// indexed with their messages' text, published widgets with their title. A result opens through the entity's
// `OpenIntent` (`OpenConversationIntent`, `OpenSurfaceIntent`).

extension ConversationEntity: IndexedEntity {
    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = defaultAttributeSet
        attributes.title = title
        if let text {
            attributes.contentDescription = String(text.prefix(300))
            attributes.textContent = text
        }
        attributes.contentModificationDate = updatedAt
        return attributes
    }
}

extension PublishedSurfaceEntity: IndexedEntity {
    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = defaultAttributeSet
        attributes.title = title
        attributes.contentDescription = "Pi widget"
        return attributes
    }
}

/// Keeps the index in step with the conversation list and the published widgets. Remembers what it indexed (each
/// conversation's `updatedAt`), so a sync re-reads only conversations that changed.
@MainActor
final class SpotlightIndex {
    private static let key = "spotlightIndexed"
    private let settings = UserDefaults.standard
    /// Conversation ID → the `updatedAt` it was indexed at.
    private var indexed: [String: Double]
    /// Conversations to re-read whatever their `updatedAt` says.
    private var stale: Set<Int> = []
    private var running: Task<Void, Never>?
    private var again = false

    init() {
        indexed = settings.dictionary(forKey: Self.key) as? [String: Double] ?? [:]
    }

    /// Re-indexes conversations that changed since their last sync, plus `refresh` (a run just ended, so its text grew
    /// though `updatedAt` did not), and removes what is gone. Calls during a sync coalesce into one more sync.
    func sync(_ store: ChatStore, refresh: Set<Int> = []) {
        stale.formUnion(refresh)
        if running != nil {
            again = true
            return
        }
        running = Task {
            repeat {
                again = false
                await run(store)
            } while again
            running = nil
        }
    }

    private func run(_ store: ChatStore) async {
        let conversations = store.conversations
        let refresh = stale
        stale = []
        let changed = conversations.filter { refresh.contains($0.id) || indexed[String($0.id)] != $0.updatedAt }.prefix(40)
        // Past the first 40, the rest wait for the next sync.
        stale.formUnion(refresh.subtracting(changed.map(\.id)))
        var entities: [ConversationEntity] = []
        for meta in changed {
            var entity = ConversationEntity(meta)
            entity.text = await store.searchText(meta.id)
            entities.append(entity)
        }
        let live = Set(conversations.map { String($0.id) })
        let gone = indexed.keys.filter { !live.contains($0) }
        do {
            if !entities.isEmpty { try await CSSearchableIndex.default().indexAppEntities(entities) }
            if !gone.isEmpty { try await CSSearchableIndex.default().deleteAppEntities(identifiedBy: gone.compactMap(Int.init), ofType: ConversationEntity.self) }
            for meta in changed { indexed[String(meta.id)] = meta.updatedAt }
            for id in gone { indexed[id] = nil }
            settings.set(indexed, forKey: Self.key)

            // Published widgets are few: replace them all.
            let widgets = (SurfaceStore.shared?.published() ?? []).map { PublishedSurfaceEntity(id: $0.publishedId, title: $0.parsed.title) }
            try await CSSearchableIndex.default().deleteAppEntities(ofType: PublishedSurfaceEntity.self)
            if !widgets.isEmpty { try await CSSearchableIndex.default().indexAppEntities(widgets) }
            if !entities.isEmpty || !gone.isEmpty {
                store.diagnostics.record("info", "spotlight", "Indexed \(entities.count) conversations, removed \(gone.count)")
            }
        } catch {
            stale.formUnion(refresh)
            store.diagnostics.record("warn", "spotlight", "Indexing failed: \(error)")
        }
    }
}
