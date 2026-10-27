import SwiftUI

/// What a button or checklist row in a surface does when tapped. A widget hands only the action's ID to its App
/// Intent; the app reads the action back from the same published spec (`SurfaceSpec.action(_:)`), so a tap can never
/// carry anything the spec does not say.
public enum SurfaceAction: Sendable, Hashable {
    /// An `ActionRow` button with `prompt`: the prompt goes to the surface's conversation.
    case prompt(title: String, prompt: String)
    /// An `ActionRow` button with `set`: stores `value` under the `$doc` key, no model run.
    case set(key: String, value: JSONValue)
    /// A `Checklist` row bound to a `$doc` list: flips `done` of the item at `index`.
    case toggle(key: String, index: Int)
    /// A `Checklist` row bound to `$reminders.*`: completes the reminder with that EventKit identifier. The app does
    /// this itself, with no model run; completing twice is the same as once.
    case completeReminder(id: String)

    /// The shape `PiRuntime.widgetAction` takes (`WidgetAction` in js/src/app/chat.ts).
    public var json: JSONValue {
        switch self {
        case let .prompt(title, prompt): ["kind": "prompt", "title": .string(title), "prompt": .string(prompt)]
        case let .set(key, value): ["kind": "set", "key": .string(key), "value": value]
        case let .toggle(key, index): ["kind": "toggle", "key": .string(key), "index": .number(Double(index))]
        case let .completeReminder(id): ["kind": "completeReminder", "id": .string(id)]
        }
    }

    /// `a<slot>.<button>` for an ActionRow button, `t<slot>.<item>` for a `$doc` checklist row, `r<slot>.<reminder ID>`
    /// for a reminder row (by ID, not position: the list may have changed between the render and the tap).
    static func id(button: Int, slot: Int) -> String { "a\(slot).\(button)" }
    static func id(item: Int, slot: Int) -> String { "t\(slot).\(item)" }
    static func id(reminder: String, slot: Int) -> String { "r\(slot).\(reminder)" }
}

extension SurfaceSpec {
    /// The action an ID names in this spec; nil when the spec (perhaps republished since the tap) has none there.
    public func action(_ id: String) -> SurfaceAction? {
        guard let kind = id.first else { return nil }
        if kind == "r" {
            // The reminder ID may hold dots; only the first one separates it from the slot.
            let parts = id.dropFirst().split(separator: ".", maxSplits: 1)
            guard parts.count == 2, let index = Int(parts[0]), let slot = slots.first(where: { $0.index == index }),
                  slot.component == "Checklist", slot["items"]?.string.flatMap(Self.remindersSource) != nil
            else { return nil }
            return .completeReminder(id: String(parts[1]))
        }
        guard kind == "a" || kind == "t" else { return nil }
        let numbers = id.dropFirst().split(separator: ".").compactMap { Int($0) }
        guard numbers.count == 2, let slot = slots.first(where: { $0.index == numbers[0] }) else { return nil }
        if kind == "a" {
            guard slot.component == "ActionRow", let button = slot["actions"]?[numbers[1]] else { return nil }
            let title = button["title"]?.display ?? ""
            if let prompt = button["prompt"]?.string { return .prompt(title: title, prompt: prompt) }
            if let key = button["set"]?.string, let value = button["value"] { return .set(key: key, value: value) }
            return nil
        }
        guard slot.component == "Checklist", let key = slot["items"]?.string.flatMap(Self.docKey) else { return nil }
        return .toggle(key: key, index: numbers[1])
    }

    /// `$reminders.open` → `reminders.open`; other bindings and literals → nil.
    static func remindersSource(_ binding: String) -> String? {
        DataSources.binding(binding).map(\.source).flatMap { $0.hasPrefix("reminders.") ? $0 : nil }
    }

    /// `$doc.todo` → `todo`; other bindings and literals → nil.
    static func docKey(_ binding: String) -> String? {
        guard binding.hasPrefix("$doc."), binding.count > 5 else { return nil }
        return String(binding.dropFirst(5))
    }
}

/// Wraps a tappable part of a surface in what performs its action: the widget passes a `Button(intent:)` for its App
/// Intent, the app a button that calls Pi directly. Without one (previews, snapshots) actions draw inert.
public struct SurfaceActionHandler: Sendable {
    public let wrap: @MainActor @Sendable (_ actionId: String, _ label: AnyView) -> AnyView

    public init(wrap: @escaping @MainActor @Sendable (_ actionId: String, _ label: AnyView) -> AnyView) {
        self.wrap = wrap
    }
}

extension EnvironmentValues {
    @Entry public var surfaceActions: SurfaceActionHandler?
    /// Drawing into an image (`ImageRenderer`), which shows platform controls such as `Link` as a "prohibited" box:
    /// links draw as their label.
    @Entry public var surfaceIsStill = false
}

extension View {
    /// `self` as the label of action `id`, when the environment has a handler.
    @MainActor @ViewBuilder func surfaceAction(_ id: String?, _ handler: SurfaceActionHandler?) -> some View {
        if let id, let handler { handler.wrap(id, AnyView(self)) } else { self }
    }
}
