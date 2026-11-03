import Foundation
import ReflectCore

/// A page of the graph — a body
/// of Markdown, tags, and any other fields.
public struct Page: Equatable, Sendable {
    /// What the page is called, and linked by.
    public var title: String
    /// Its lasting identity, a ULID, which survives renames. Nil for a file
    /// written by hand without one.
    public var id: String?
    public var tags: [String]
    public var created: Date?
    public var modified: Date?
    /// Every other field, in the order written.
    public var fields: [Field]
    /// The body, Markdown.
    public var text: String

    public init(title: String, id: String? = nil, tags: [String] = [], created: Date? = nil, modified: Date? = nil,
                fields: [Field] = [], text: String = "") {
        self.title = title
        self.id = id
        self.tags = tags
        self.created = created
        self.modified = modified
        self.fields = fields
        self.text = text
    }

    public struct Field: Equatable, Sendable {
        public var name: String
        public var value: Value

        public init(_ name: String, _ value: Value) {
            self.name = name
            self.value = value
        }
    }

    /// A field's value: text, or a list of titles (as `list` is, the order
    /// of a tag's pages).
    public enum Value: Equatable, Sendable {
        case text(String)
        case list([String])

        public var text: String? {
            if case .text(let text) = self { return text }
            return nil
        }

        public var list: [String]? {
            if case .list(let list) = self { return list }
            return nil
        }
    }

    /// The fields the page's own properties stand for, not kept in `fields`.
    public static let reservedFields: Set<String> = ["title", "id", "tags", "created", "modified"]

    /// A page that is itself a thing to do, open or done: `task: todo`, and
    /// once done `task: done` — the day it was done in `done:`, set by
    /// whoever checks it off. Nil, a page that is not one.
    public enum TaskState: String, CaseIterable, Sendable { case todo, done }

    public var taskState: TaskState? {
        get { self[field: "task"]?.text.flatMap { TaskState(rawValue: $0.trimmingCharacters(in: .whitespaces).lowercased()) } }
        set {
            self[field: "task"] = newValue.map { .text($0.rawValue) }
            if newValue != .done { self[field: "done"] = nil }
        }
    }

    /// Whether the page is part of the wiki — canonical, kept up — rather
    /// than a passing note: `wiki: true`.
    public var isWiki: Bool {
        get { self[field: "wiki"]?.text.map(FieldSpec.flag) ?? false }
        set { self[field: "wiki"] = newValue ? .text("true") : nil }
    }

    public subscript(field name: String) -> Value? {
        get { fields.first { $0.name == name }?.value }
        set {
            if let index = fields.firstIndex(where: { $0.name == name }) {
                if let newValue { fields[index].value = newValue } else { fields.remove(at: index) }
            } else if let newValue {
                fields.append(Field(name, newValue))
            }
        }
    }
}

extension Page {
    /// A new page's id: a ULID, as Reflect gives its notes.
    public static func newID() -> String { NoteCreation.ulid() }
}
