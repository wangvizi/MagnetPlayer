import Foundation

struct FileItem: Identifiable, Codable, Hashable {
    let index: Int
    let name: String
    let size: Int64
    var id: Int { index }
}

struct ParseResult: Codable {
    let name: String
    let files: [FileItem]
}

struct StreamResult: Codable {
    let hlsURL: String
}

enum APIError: LocalizedError {
    case badURL
    case server(String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .badURL: return "服务器地址无效"
        case .server(let m): return "服务器错误：\(m)"
        case .transport(let m): return "连接失败：\(m)"
        }
    }
}

final class APIClient {
    static let shared = APIClient()

    private func post<T: Decodable>(_ path: String, body: [String: Any], as: T.Type) async throws -> T {
        guard let url = URL(string: Config.serverURL + path) else {
            throw APIError.badURL
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 300
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data, resp: URLResponse
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch {
            throw APIError.transport(error.localizedDescription)
        }
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            let msg = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw APIError.server(msg)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    func parse(magnet: String) async throws -> ParseResult {
        try await post("/api/parse", body: ["magnet": magnet], as: ParseResult.self)
    }

    func stream(magnet: String, index: Int) async throws -> StreamResult {
        try await post("/api/stream", body: ["magnet": magnet, "index": index], as: StreamResult.self)
    }
}