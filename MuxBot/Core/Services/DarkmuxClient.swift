import Foundation

/// Talks to darkmux's local client endpoint on this Mac (loopback only):
/// pairing, then real runs for a paired client. Prototype contract, local
/// darkmux build only.
struct DarkmuxClient: Sendable {
    var baseURL = URL(string: "http://127.0.0.1:8767")!

    /// What a pairing asks for. darkmux decides what apps may actually run
    /// (a machine setting), so the reply may carry less or nothing.
    struct Scopes: Codable, Sendable, Equatable {
        var profiles: [String]?
        var workspace: Bool?
    }

    struct PairStatus: Decodable, Sendable {
        var status: String
        var clientName: String?
        var token: String?
        var scopes: Scopes?
        enum CodingKeys: String, CodingKey { case status, token, scopes; case clientName = "client_name" }
    }

    struct WorkStatus: Decodable, Sendable {
        var status: String
        var error: String?
        var finalAssistant: String?
        enum CodingKeys: String, CodingKey { case status, error, result }
        enum ResultKeys: String, CodingKey { case finalAssistant = "final_assistant" }
        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            status = try c.decode(String.self, forKey: .status)
            error = try c.decodeIfPresent(String.self, forKey: .error)
            let result = try? c.nestedContainer(keyedBy: ResultKeys.self, forKey: .result)
            finalAssistant = try result?.decodeIfPresent(String.self, forKey: .finalAssistant)
        }
    }

    struct ClientError: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    func requestPairing(deviceName: String, code: String, secret: String, scopes: Scopes) async throws -> String {
        struct Body: Encodable { var device_name: String; var code: String; var pair_secret: String; var scopes: Scopes }
        struct Reply: Decodable { var request_id: String }
        let data = try await send("POST", "/client/pair", body: Body(device_name: deviceName, code: code, pair_secret: secret, scopes: scopes))
        return try JSONDecoder().decode(Reply.self, from: data).request_id
    }

    func pairStatus(requestId: String, secret: String) async throws -> PairStatus {
        let data = try await send("GET", "/client/pair/\(requestId)", headers: ["X-Pair-Secret": secret])
        return try JSONDecoder().decode(PairStatus.self, from: data)
    }

    /// Starts a run. `profile` nil lets darkmux pick it the way
    /// `darkmux dispatch <role>` would; the reply names the profile used.
    func submitWork(token: String, role: String, message: String, profile: String?, workdir: String?) async throws -> (workId: String, profile: String?) {
        struct Body: Encodable { var role: String; var message: String; var profile: String?; var workdir: String? }
        struct Reply: Decodable { var work_id: String; var profile: String? }
        let data = try await send("POST", "/client/work", body: Body(role: role, message: message, profile: profile, workdir: workdir),
                                  headers: ["Authorization": "Bearer \(token)"])
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        return (reply.work_id, reply.profile)
    }

    /// The preview recipe in a work folder darkmux lets this app use; nil
    /// when the folder has none.
    func recipe(token: String, workdir: String) async throws -> PreviewManifest? {
        struct Reply: Decodable { var recipe: PreviewManifest }
        var parts = URLComponents(url: baseURL.appending(path: "/client/recipe"), resolvingAgainstBaseURL: false)
        parts?.queryItems = [URLQueryItem(name: "workdir", value: workdir)]
        guard let url = parts?.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { return nil }
        guard status == 200 else { throw ClientError(message: "darkmux answered \(status)") }
        return try JSONDecoder().decode(Reply.self, from: data).recipe
    }

    func cancelWork(token: String, workId: String) async throws {
        _ = try await send("POST", "/client/work/\(workId)/cancel", headers: ["Authorization": "Bearer \(token)"])
    }

    func workStatus(token: String, workId: String) async throws -> WorkStatus {
        let data = try await send("GET", "/client/work/\(workId)", headers: ["Authorization": "Bearer \(token)"])
        return try JSONDecoder().decode(WorkStatus.self, from: data)
    }

    private func send(_ method: String, _ path: String, body: (some Encodable)? = Optional<String>.none,
                      headers: [String: String] = [:]) async throws -> Data {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.timeoutInterval = 5
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw ClientError(message: detail ?? "darkmux answered \(status)")
        }
        return data
    }
}

extension CrewRole {
    /// The darkmux built-in role that does this crew role's work; nil when
    /// there isn't one yet (that crew role stays simulated).
    var darkmuxRole: String? {
        switch self {
        case .coder: "coder"
        case .reviewer: "code-reviewer"
        case .researcher: "analyst"
        case .evalRunner: nil
        }
    }
}
