import Foundation
import os

// HermesServeClient's Dashboard REST: profiles, skills, toolsets, files, and the request helpers.
extension HermesServeClient {
    // MARK: - Skills (dashboard REST, cookie-authenticated)

    nonisolated struct DashboardSkill: Decodable, Identifiable, Sendable {
        var name: String
        var description: String?
        var category: String?
        var enabled: Bool?
        var id: String { name }
    }

    /// One Hermes profile from the dashboard's `GET /api/profiles`.
    nonisolated struct Profile: Decodable, Identifiable, Equatable, Sendable {
        var name: String
        var path: String
        var isDefault: Bool
        var displayName: String?
        var description: String?
        var id: String { name }
        var title: String { displayName?.nilIfEmpty ?? name }
        enum CodingKeys: String, CodingKey {
            case name, path, description
            case isDefault = "is_default", displayName = "display_name"
        }
    }

    /// Every profile on the server (the list the desktop app shows), default first.
    func profiles() async throws -> [Profile] {
        struct Envelope: Decodable { var profiles: [Profile] }
        let list = try JSONDecoder().decode(Envelope.self, from: try await rest("GET", "api/profiles", body: nil as Data?)).profiles
        return list.filter(\.isDefault) + list.filter { !$0.isDefault }
    }

    /// Where the profile in use keeps its files (its Hermes home), as the profile list says:
    /// `~/.hermes` usually, but HERMES_HOME itself where that is set, as Hermes's Docker image
    /// does (`/opt/data`). Nil when the list can't be had or doesn't say (GitHub issue 15).
    func profileHome() async -> String? {
        guard let listed = try? await profiles() else { return nil }
        let profile = if let name = settings.profileName {
            listed.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        } else {
            listed.first(where: \.isDefault)
        }
        return profile?.path.nilIfEmpty
    }

    /// A profile's SOUL.md through the Dashboard's own route, which finds the profile's folder by
    /// itself; nil when it has none yet. (The file routes read where the terminal works, which
    /// from 0.22 can be another machine over SSH.)
    func soul(profile: String) async throws -> String? {
        struct Envelope: Decodable { var content: String; var exists: Bool }
        let envelope = try JSONDecoder().decode(Envelope.self, from: try await rest("GET", "api/profiles/\(profile)/soul", body: nil as Data?))
        return envelope.exists ? envelope.content : nil
    }

    func setSoul(profile: String, content: String) async throws {
        struct Body: Encodable { var content: String }
        _ = try await rest("PUT", "api/profiles/\(profile)/soul", body: try JSONEncoder().encode(Body(content: content)))
    }

    /// The skills, with whether each is on: the selected profile's, or `profile`'s (a bot's).
    func dashboardSkills(profile: String? = nil) async throws -> [DashboardSkill] {
        let data = try await rest("GET", Self.naming("api/skills", profile: profile), body: nil as Data?)
        if let list = try? JSONDecoder().decode([DashboardSkill].self, from: data) { return list }
        struct Envelope: Decodable { var skills: [DashboardSkill]? ; var data: [DashboardSkill]? }
        let env = try JSONDecoder().decode(Envelope.self, from: data)
        return env.skills ?? env.data ?? []
    }

    /// Same shape the API server's /v1/toolsets returns, from the dashboard's own endpoint.
    func dashboardToolsets() async throws -> [HermesSessionsAPI.Toolset] {
        let data = try await rest("GET", "api/tools/toolsets", body: nil as Data?)
        return try JSONDecoder().decode([HermesSessionsAPI.Toolset].self, from: data)
    }

    /// Enable/disable a toolset for its configuration platform, as the dashboard does.
    func toggleToolset(name: String, enabled: Bool) async throws {
        try await switchToolset(name: name, enabled: enabled)
        Task { await refreshOpenChatsTools() }
    }

    /// The Dashboard's own switch, alone: the main profile's toolsets as its chats read them, on
    /// every release (0.21.0 kept a profiles.configure list for the main profile where its chats
    /// never looked).
    func switchToolset(name: String, enabled: Bool) async throws {
        struct Body: Encodable { var enabled: Bool }
        _ = try await rest("PUT", "api/tools/toolsets/\(name)", body: try JSONEncoder().encode(Body(enabled: enabled)))
    }

    /// Gives the open chats their profiles' tools as they now stand: Hermes fixes a chat's tools
    /// when it starts, so a change reached only new chats until the Dashboard restarted (his
    /// Code Execution switch, 2026-10-22). The Dashboard's own /reload-mcp, which also reconnects
    /// the MCP servers. Best effort.
    func refreshOpenChatsTools() async {
        do {
            try await ensureConnected()
            _ = try await call("reload.mcp", params: .object(["confirm": .bool(true)]), timeout: 90)
        } catch {
            log.notice("open chats' tools not refreshed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func skillContent(name: String) async throws -> String {
        var comps = URLComponents()
        comps.path = "api/skills/content"
        comps.queryItems = [.init(name: "name", value: name)]
        let data = try await rest("GET", comps.string ?? "api/skills/content", body: nil as Data?)
        struct Envelope: Decodable { var content: String }
        return try JSONDecoder().decode(Envelope.self, from: data).content
    }

    func createSkill(name: String, content: String, category: String?) async throws {
        struct Body: Encodable { var name: String; var content: String; var category: String? }
        _ = try await rest("POST", "api/skills", body: try JSONEncoder().encode(Body(name: name, content: content, category: category?.nilIfEmpty)))
    }

    func updateSkill(name: String, content: String) async throws {
        struct Body: Encodable { var name: String; var content: String }
        _ = try await rest("PUT", "api/skills/content", body: try JSONEncoder().encode(Body(name: name, content: content)))
    }

    /// A skill on or off for the selected profile, or for `profile` (a bot's): off, the agent
    /// neither sees it listed nor can load it (`skills.disabled` in that profile's config).
    func toggleSkill(name: String, enabled: Bool, profile: String? = nil) async throws {
        struct Body: Encodable { var name: String; var enabled: Bool }
        _ = try await rest("PUT", Self.naming("api/skills/toggle", profile: profile),
                           body: try JSONEncoder().encode(Body(name: name, enabled: enabled)))
    }

    /// The skills a profile reads in full at the start of every message (`skills.auto_load` in its
    /// config), as against the rest, listed and read only when needed.
    func alwaysLoadedSkills(profile: String) async throws -> [String] {
        let config = try await restJSON("GET", Self.naming("api/config?include_defaults=false", profile: profile))
        return (config["skills"]?["auto_load"]?.array ?? []).compactMap(\.string)
    }

    /// Sets them. The Dashboard merges what it is sent into the profile's config (every release from
    /// 0.21.0), and a list replaces the one there, so nothing else in it changes.
    func setAlwaysLoadedSkills(_ names: [String], profile: String) async throws {
        let body: JSONValue = .object(["config": .object(["skills": .object(["auto_load": .array(names.map(JSONValue.string))])])])
        _ = try await restJSON("PUT", Self.naming("api/config", profile: profile), body: body)
    }

    /// A route for one profile in particular, whichever is selected (`scoped` keeps a path's own).
    nonisolated static func naming(_ path: String, profile: String?) -> String {
        guard let profile, var comps = URLComponents(string: path) else { return path }
        comps.queryItems = (comps.queryItems ?? []) + [URLQueryItem(name: "profile", value: profile)]
        return comps.string ?? path
    }

    // MARK: - Context files (SOUL.md, ENVIRONMENT.md) via the dashboard file API

    /// Reads a text file on the gateway host. `~` expands server-side. Nil when the file is missing.
    func readText(path: String) async throws -> String? {
        var comps = URLComponents()
        comps.path = "api/fs/read-text"
        comps.queryItems = [.init(name: "path", value: path)]
        do {
            let data = try await rest("GET", comps.string ?? "api/fs/read-text", body: nil as Data?)
            struct Envelope: Decodable { var text: String; var truncated: Bool? }
            return try JSONDecoder().decode(Envelope.self, from: data).text
        } catch let TransportError.http(status, _) where status == 404 {
            return nil
        }
    }

    /// Reads a file on the gateway host as a `data:` URL (`/api/fs/read-data-url`). Nil when the
    /// file is missing or over the server's size cap.
    /// A file as a data URL (16 MB at most: nil over that, and when it isn't there). `in`: the
    /// session whose folder a relative path is in, and the profile it belongs to (a bot's).
    /// A picture put on the server as the Dashboard's own chat puts one (`POST /api/chat/image-upload`,
    /// into the profile's pictures folder; PNG, JPEG, GIF, WebP or BMP, 25 MB at most): its path there.
    func uploadPicture(_ picture: Attachment) async throws -> String {
        let reply = try await restJSON("POST", "api/chat/image-upload",
                                       body: .object(["data_url": .string(picture.dataURL), "filename": .string(picture.filename)]))
        guard let path = reply["path"]?.string, !path.isEmpty else { throw TransportError.malformed("no path for the picture") }
        return path
    }

    func readDataURL(path: String, in source: FileSource? = nil) async throws -> String? {
        var comps = URLComponents()
        comps.path = "api/fs/read-data-url"
        comps.queryItems = [.init(name: "path", value: path)] + (source?.queryItems(for: path) ?? [])
        do {
            let data = try await rest("GET", comps.string ?? "api/fs/read-data-url", body: nil as Data?)
            struct Envelope: Decodable { var dataUrl: String }
            return try JSONDecoder().decode(Envelope.self, from: data).dataUrl
        } catch let TransportError.http(status, _) where status == 404 || status == 413 {
            return nil
        }
    }

    /// A file an agent's reply named, saved to a temporary file (no size limit, unlike
    /// `readDataURL`): the desktop app's download route, by path.
    func downloadDelivered(path: String, in source: FileSource?) async throws -> URL {
        var comps = URLComponents()
        comps.path = "api/fs/download"
        comps.queryItems = [.init(name: "path", value: path)] + (source?.queryItems(for: path) ?? [])
        let fetched = try await restDownload(comps.string?.replacingOccurrences(of: "+", with: "%2B") ?? "api/fs/download")
        let copy = try ServerFiles.localCopy(named: String(path.split(separator: "/").last ?? "file"))
        try FileManager.default.moveItem(at: fetched, to: copy)
        return copy
    }

    func writeText(path: String, content: String) async throws {
        struct Body: Encodable { var path: String; var content: String }
        _ = try await rest("POST", "api/fs/write-text", body: try JSONEncoder().encode(Body(path: path, content: content)))
    }

    /// Dashboard REST returning JSON; `path` is relative to the serve base (query string allowed).
    func restJSON(_ method: String, _ path: String, body: JSONValue? = nil, timeout: TimeInterval = 30, about stored: String? = nil) async throws -> JSONValue {
        let data = try await rest(method, path, body: body.map { try Self.encoder.encode($0) }, timeout: timeout, about: stored)
        if data.isEmpty { return .null }
        return try JSONValue.parse(data)
    }

    /// How a dashboard REST call names a profile: in the JSON body for the routes whose request
    /// models carry `profile` but take no query param, as `?profile=` for the other profile-aware
    /// routes Redde calls, not at all for the rest (files take paths; the Kanban board is shared).
    nonisolated enum ProfilePlacement: Equatable { case none, query, body }

    nonisolated static func profilePlacement(method: String, path: String) -> ProfilePlacement {
        let route = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        switch (method, route) {
        case ("PATCH", _) where route.hasPrefix("api/sessions/"): return .body
        case ("POST", "api/skills"), ("PUT", "api/skills/content"): return .body
        case (_, "api/sessions"): return method == "GET" ? .query : .none
        case ("GET", _) where route.hasPrefix("api/sessions/") && route.hasSuffix("/messages"): return .query
        case ("GET", _) where route.hasPrefix("api/sessions/") && route.hasSuffix("/mutation-snapshot"): return .query
        default:
            let queryRoutes = ["api/skills", "api/tools/toolsets", "api/cron/", "api/mcp/servers", "api/logs", "api/status", "api/gateway/restart",
                               "api/sessions/search", "api/audio/speak", "api/audio/voice-live/", "api/chat/image-upload"]
            return queryRoutes.contains { route == $0 || route.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") } ? .query : .none
        }
    }

    /// The path and body with the selected profile added where the route takes one.
    nonisolated static func scoped(method: String, path: String, body: Data?, profile: String?) -> (String, Data?) {
        guard let profile else { return (path, body) }
        switch profilePlacement(method: method, path: path) {
        case .none:
            return (path, body)
        case .query:
            // A path that already names a profile (cron's `profile=all` list) keeps it.
            if path.contains("profile=") { return (path, body) }
            guard var comps = URLComponents(string: path) else { return (path, body) }
            comps.queryItems = (comps.queryItems ?? []) + [URLQueryItem(name: "profile", value: profile)]
            return (comps.string ?? path, body)
        case .body:
            guard let body, var object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  object["profile"] == nil else { return (path, body) }
            object["profile"] = profile
            return (path, (try? JSONSerialization.data(withJSONObject: object)) ?? body)
        }
    }

    /// `about`: the stored session the call is about, when there is one: a bot's chat is in the
    /// bot's profile.
    func rest(_ method: String, _ path: String, body: Data?, timeout: TimeInterval = 30, about stored: String? = nil) async throws -> Data {
        do { return try await restNow(method, path, body: body, timeout: timeout, about: stored) } catch {
            FailureLog.shared.record(via: "dashboard rest", what: "\(method) \(path)", error: error)
            throw error
        }
    }

    private func restNow(_ method: String, _ path: String, body: Data?, timeout: TimeInterval, about stored: String?) async throws -> Data {
        guard let baseURL else { throw TransportError.badURL }
        try await login(baseURL: baseURL)
        let profile = stored.flatMap { sessionProfiles[$0] } ?? settings.profileName
        let (path, body) = Self.scoped(method: method, path: path, body: body, profile: profile)
        guard let url = URL(string: path, relativeTo: baseURL.appending(path: "/"))?.absoluteURL else { throw TransportError.badURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        let (data, response) = try await send(request, baseURL: baseURL)
        guard let http = response as? HTTPURLResponse else { throw TransportError.malformed("not HTTP") }
        guard (200 ..< 300).contains(http.statusCode) else { throw Self.refusal(http.statusCode, data) }
        return data
    }

    /// A Dashboard GET's answer as it comes: a file, not JSON.
    func restData(_ path: String, timeout: TimeInterval = 30) async throws -> Data {
        try await rest("GET", path, body: nil, timeout: timeout)
    }

    /// Deletes a profile and everything in it (Dashboard REST: Hermes has no socket call for it).
    /// Hermes stops what runs for it first, waiting up to 10 seconds.
    func deleteProfile(_ name: String) async throws {
        let path = "api/profiles/" + (name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name)
        _ = try await rest("DELETE", path, body: nil, timeout: 45)
    }

    /// What a Dashboard REST call refused with, as `rest` reports it.
    static func refusal(_ status: Int, _ data: Data) -> TransportError {
        struct Detail: Decodable { var detail: String? }
        let detail = (try? JSONDecoder().decode(Detail.self, from: data))?.detail
        return .http(status: status, body: detail ?? String(decoding: data.prefix(200), as: UTF8.self))
    }

    /// A Dashboard GET whose answer is saved to a file and not held in memory (a download). The
    /// file is the system's temporary one: the caller moves it where it wants it. `watch` hears
    /// of the transfer as it goes, for a progress bar.
    func restDownload(_ path: String, watch: (any URLSessionTaskDelegate)? = nil) async throws -> URL {
        guard let baseURL else { throw TransportError.badURL }
        try await login(baseURL: baseURL)
        guard let url = URL(string: path, relativeTo: baseURL.appending(path: "/"))?.absoluteURL else { throw TransportError.badURL }
        var request = URLRequest(url: url)
        request.timeoutInterval = 60   // between packets, not for the whole file
        let (file, response) = try await send(request, baseURL: baseURL) { try await self.session.download(for: $0, delegate: watch) }
        guard let http = response as? HTTPURLResponse else { throw TransportError.malformed("not HTTP") }
        guard (200 ..< 300).contains(http.statusCode) else {
            // A refusal is saved like anything else: its few words are in the file.
            let said = (try? Data(contentsOf: file)) ?? Data()
            try? FileManager.default.removeItem(at: file)
            throw Self.refusal(http.statusCode, said)
        }
        return file
    }

    /// A Dashboard POST whose body is a file on disk (a multipart form written out beforehand),
    /// so an upload is never held in memory whole.
    func restUpload(_ path: String, bodyFile: URL, contentType: String, watch: (any URLSessionTaskDelegate)? = nil) async throws -> JSONValue {
        guard let baseURL else { throw TransportError.badURL }
        try await login(baseURL: baseURL)
        guard let url = URL(string: path, relativeTo: baseURL.appending(path: "/"))?.absoluteURL else { throw TransportError.badURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        let (data, response) = try await send(request, baseURL: baseURL) { try await self.session.upload(for: $0, fromFile: bodyFile, delegate: watch) }
        guard let http = response as? HTTPURLResponse else { throw TransportError.malformed("not HTTP") }
        guard (200 ..< 300).contains(http.statusCode) else { throw Self.refusal(http.statusCode, data) }
        return data.isEmpty ? .null : try JSONValue.parse(data)
    }
}
