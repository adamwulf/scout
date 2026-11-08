/// Output formats for commands that return one page of resources.
public enum ListFormat: String, CaseIterable, Sendable {
    case table, json, jsonl, id
}

/// Output formats for commands that return one resource. `raw` is only meaningful for templates.
public enum DetailFormat: String, CaseIterable, Sendable {
    case markdown, json, raw
}

/// The Help Scout resource a renderer receives, used to pick table columns and markdown labels.
public enum ResourceKind: Sendable {
    case inbox, conversation, customer, template
}
