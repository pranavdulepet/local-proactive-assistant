import Foundation

public struct AgentToolCall: Codable, Equatable, Sendable {
    public let id: String
    public let call: ContextToolCall
    public init(id: String, call: ContextToolCall) { self.id = id; self.call = call }
}

public struct AgentMessage: Codable, Equatable, Sendable {
    public enum Role: String, Codable, Sendable { case system, user, assistant, tool }
    public let role: Role
    public let content: String
    public let toolCalls: [AgentToolCall]
    public let toolCallID: String?
    public init(role: Role, content: String, toolCalls: [AgentToolCall] = [], toolCallID: String? = nil) {
        self.role = role; self.content = content; self.toolCalls = toolCalls; self.toolCallID = toolCallID
    }
}

public struct AgentRequest: Codable, Equatable, Sendable {
    public let messages: [AgentMessage]
    public let availableTools: [ContextTool]
    public init(messages: [AgentMessage], availableTools: [ContextTool]) {
        self.messages = messages; self.availableTools = availableTools
    }

    public func validate() throws {
        guard !messages.isEmpty, messages.count <= 48,
              messages.reduce(0, { $0 + $1.content.utf8.count }) <= 131_072,
              Set(availableTools).count == availableTools.count else {
            throw AgentProtocolFailure("Agent conversation exceeds its bounds.")
        }
        var pending = Set<String>()
        var allIDs = Set<String>()
        for message in messages {
            guard message.content.utf8.count <= 16_384,
                  message.role == .assistant || message.toolCalls.isEmpty else {
                throw AgentProtocolFailure("Invalid agent message role or size.")
            }
            if message.role == .tool {
                guard let id = message.toolCallID, pending.remove(id) != nil else {
                    throw AgentProtocolFailure("Tool result has no matching assistant call.")
                }
            } else {
                guard message.toolCallID == nil, pending.isEmpty else {
                    throw AgentProtocolFailure("Assistant tool calls require results before conversation continues.")
                }
            }
            for tool in message.toolCalls {
                try tool.call.validate()
                guard !tool.id.isEmpty, tool.id.utf8.count <= 128, allIDs.insert(tool.id).inserted else {
                    throw AgentProtocolFailure("Invalid or repeated tool call identifier.")
                }
                pending.insert(tool.id)
            }
        }
        guard pending.isEmpty else { throw AgentProtocolFailure("Agent conversation has unanswered tool calls.") }
    }
}

public struct AgentStep: Codable, Equatable, Sendable {
    public let text: String
    public let calls: [AgentToolCall]
    public init(text: String, calls: [AgentToolCall]) { self.text = text; self.calls = calls }
    public func validate(for request: AgentRequest) throws {
        try request.validate()
        guard text.utf8.count <= 8_192, calls.count <= 8,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !calls.isEmpty,
              Set(calls.map(\.id)).count == calls.count else {
            throw AgentProtocolFailure("The local model returned an invalid agent step.")
        }
        for call in calls {
            try call.call.validate()
            guard !call.id.isEmpty, call.id.utf8.count <= 128,
                  request.availableTools.contains(call.call.tool) else {
                throw AgentProtocolFailure("The local model requested an unavailable read tool.")
            }
        }
    }
}

public struct AgentToolsUnavailable: Error, Sendable {
    public init() {}
}

public struct AgentProtocolFailure: Error, CustomStringConvertible, Sendable {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// Function names and bounded argument schemas shared by local native tool-call protocols.
public enum AgentToolCatalog {
    public static func definitions(for tools: [ContextTool]) -> [[String: Any]] {
        tools.map { tool in
            ["type": "function", "function": ["name": tool.rawValue,
                "description": description(for: tool), "parameters": parameters(for: tool)]]
        }
    }

    public static func decode(name: String, arguments: [String: Any]) throws -> ContextToolCall {
        guard let tool = ContextTool(rawValue: name),
              Set(arguments.keys).isSubset(of: Set(parameterNames(for: tool))) else {
            throw AgentProtocolFailure("Unknown read tool or argument.")
        }
        var object = arguments
        object["tool"] = name
        do {
            let call = try JSONDecoder().decode(ContextToolCall.self,
                from: JSONSerialization.data(withJSONObject: object))
            try call.validate()
            return call
        } catch { throw AgentProtocolFailure("Invalid arguments for the requested read tool.") }
    }

    public static func arguments(for call: ContextToolCall) throws -> [String: Any] {
        try call.validate()
        guard var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(call)) as? [String: Any] else {
            throw AgentProtocolFailure("Invalid read tool arguments.")
        }
        object.removeValue(forKey: "tool")
        return object
    }

    private static func description(for tool: ContextTool) -> String {
        switch tool.rawValue {
        case "photos":
            "Read permitted Photos metadata by creation date and media kind. Optional query is photos, videos, screenshots or favorites. Returns dates, dimensions and coarse location; does not inspect image contents or download cloud originals."
        case "messages":
            "Read indexed Messages. Use person to resolve a contact name or handle, direction inbound for what they said, outbound for what the owner said, and limit for recent messages. Optional query filters content; offset pages older results."
        case "calendar":
            "Read indexed Calendar events over an explicit ISO date or date-time range. Convert relative days using the host timezone, not UTC. Optional person or query filters events. Coverage reports the refresh window."
        case "contacts":
            "Resolve a person's name, email or phone handle from indexed Contacts. Use person or query. Do not invent an identity when multiple matches exist."
        case "mailInbox":
            "Read current Apple Mail. Omit query for the Inbox; use unread for unread Inbox. Sender, subject, topic, Archive, Sent and ISO date keywords search relevant account/local mailboxes. Use offset for older search pages and limit for the evidence sample. Coverage reports pagination and failures."
        case "searchFiles":
            "Discover locally readable files in owner-approved folders by keyword. Returns candidate paths, not complete file contents; use readFile for a discovered document."
        case "readFile":
            "Read bounded text or extracted document content from a discovered absolute path in an approved folder. This cannot run commands, access secrets or change files."
        case "notes":
            "Read a bounded Apple Notes snapshot. Optional query supplies short content keywords. Locked or unavailable notes are reported in coverage."
        case "reminders":
            "Read open Reminders. Optional query is today, tomorrow, overdue or short content keywords. This tool does not create or complete reminders."
        case "deviceInfo":
            "Read basic local Mac hardware and OS information. No arguments. This does not inspect arbitrary running applications or passwords."
        default:
            "Search the bounded local index across connected sources using concise source/topic/date keywords. Prefer messages, calendar or contacts for specific source requests."
        }
    }

    private static func parameterNames(for tool: ContextTool) -> [String] {
        switch tool.rawValue {
        case "photos": ["query", "from", "to", "limit"]
        case "messages": ["query", "person", "direction", "from", "to", "limit", "offset"]
        case "calendar": ["query", "person", "from", "to", "limit", "offset"]
        case "contacts": ["query", "person", "limit", "offset"]
        case "mailInbox": ["query", "limit", "offset"]
        case "readFile": ["path"]
        case "deviceInfo": []
        default: ["query"]
        }
    }

    private static func parameters(for tool: ContextTool) -> [String: Any] {
        var properties: [String: Any] = [:]
        for name in parameterNames(for: tool) {
            switch name {
            case "limit": properties[name] = ["type": "integer", "minimum": 1, "maximum": 8]
            case "offset": properties[name] = ["type": "integer", "minimum": 0, "maximum": tool == .mailInbox ? 5_000 : 100]
            case "direction": properties[name] = ["type": "string", "enum": ["inbound", "outbound", "any"]]
            case "path": properties[name] = ["type": "string", "maxLength": 1_024]
            case "person": properties[name] = ["type": "string", "maxLength": 128]
            case "from", "to": properties[name] = ["type": "string", "maxLength": 40, "description": "ISO YYYY-MM-DD or ISO8601 date-time in the host timezone."]
            default:
                properties[name] = tool == .photos && name == "query"
                    ? ["type": "string", "enum": ["photos", "videos", "screenshots", "favorites"]]
                    : ["type": "string", "maxLength": 256]
            }
        }
        let required: [String] = tool.rawValue == "calendar" ? ["from", "to"] : tool == .readFile ? ["path"]
            : tool == .searchFiles || tool == .searchIndex ? ["query"] : []
        return ["type": "object", "additionalProperties": false, "properties": properties, "required": required]
    }
}
