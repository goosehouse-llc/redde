import Foundation

/// One Server-Sent Event. `data` has multi-line `data:` fields joined with "\n" per the spec.
nonisolated struct SSEEvent: Equatable, Sendable {
    var event: String?
    var data: String
    var id: String?
}

/// Incremental, allocation-light SSE parser. Feed it bytes as they arrive; it yields
/// complete events. Handles CRLF/LF, comment lines (`:`), and the optional space after the colon.
nonisolated struct SSEParser: Sendable {
    private var buffer = ""
    private var pendingEvent: String?
    private var pendingData: [String] = []
    private var pendingID: String?

    mutating func feed(_ chunk: String) -> [SSEEvent] {
        buffer += chunk
        var events: [SSEEvent] = []
        while let newline = buffer.firstIndex(where: { $0 == "\n" || $0 == "\r\n" }) {
            let line = String(buffer[..<newline])
            buffer.removeSubrange(...newline)
            if let event = consume(line: line) { events.append(event) }
        }
        return events
    }

    /// One line as `LineBuffer` yields it (trailing newline included). No re-buffering and no
    /// per-character rescan: the byte splitter already found the line ends.
    mutating func feed(line: String) -> SSEEvent? {
        var line = line
        if line.last == "\n" || line.last == "\r\n" { line.removeLast() }
        return consume(line: line)
    }

    /// Call at end-of-stream to flush a final event that wasn't terminated by a blank line.
    mutating func finish() -> SSEEvent? {
        var events: [SSEEvent] = []
        if !buffer.isEmpty {
            let line = buffer
            buffer = ""
            if let e = consume(line: line) { events.append(e) }
        }
        if let e = consume(line: "") { events.append(e) }
        return events.last
    }

    private mutating func consume(line: String) -> SSEEvent? {
        if line.isEmpty {
            guard !pendingData.isEmpty || pendingEvent != nil else { return nil }
            let event = SSEEvent(event: pendingEvent, data: pendingData.joined(separator: "\n"), id: pendingID)
            pendingEvent = nil
            pendingData = []
            return event
        }
        if line.hasPrefix(":") { return nil }
        let field: Substring
        var value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[..<colon]
            value = line[line.index(after: colon)...]
            if value.first == " " { value = value.dropFirst() }
        } else {
            field = line[...]
            value = ""
        }
        switch field {
        case "event": pendingEvent = String(value)
        case "data": pendingData.append(String(value))
        case "id": pendingID = String(value)
        default: break // "retry" and unknown fields are ignored
        }
        return nil
    }
}
