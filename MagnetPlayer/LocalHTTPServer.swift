import Foundation
import Network

/// 本地 HTTP 服务器：把"正在下载的视频文件"以 Range 请求暴露给 AVPlayer。
/// AVPlayer 通过 http://127.0.0.1:<port>/ 直接播放，实现边下边播。
final class LocalHTTPServer {
    private var listener: NWListener?
    let port: UInt16

    /// 当前播放文件（尚未完整下载，边下边播）
    var fileURL: URL?
    /// 文件完整长度（用于 Content-Range 分母，便于播放器显示总进度）
    var completeLength: Int = 0
    /// 当前已落盘可用长度
    var availableLength: Int = 0

    init(port: UInt16 = 8080) { self.port = port }

    func start() throws {
        let params = NWParameters.tcp
        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        self.listener = listener
        listener.stateUpdateHandler = { state in
            if case .failed(let e) = state { print("[http] listener failed: \(e)") }
        }
        listener.newConnectionHandler = { [weak self] conn in
            self?.handle(conn)
        }
        listener.start(queue: .global())
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(_ conn: NWConnection) {
        conn.stateUpdateHandler = { _ in }
        conn.start(queue: .global())
        receiveRequest(conn)
    }

    private func receiveRequest(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, err in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.respond(to: data, conn: conn)
            }
            if isComplete || err != nil { conn.cancel(); return }
        }
    }

    private func respond(to data: Data, conn: NWConnection) {
        guard let str = String(data: data, encoding: .utf8),
              let requestLine = str.components(separatedBy: "\n").first else {
            conn.cancel(); return
        }
        var range: Range<Int>? = nil
        for line in str.components(separatedBy: "\n") where line.lowercased().hasPrefix("range:") {
            let body = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "bytes=", with: "")
            let parts = body.components(separatedBy: "-")
            if parts.count == 2, let s = Int(parts[0]) {
                let e = parts[1].isEmpty ? (availableLength - 1) : (Int(parts[1]) ?? availableLength - 1)
                range = s..<(e + 1)
            }
        }

        var body = Data()
        var header: String
        if let url = fileURL, let handle = try? FileHandle(forReadingFrom: url) {
            defer { try? handle.close() }
            if var r = range, r.lowerBound < availableLength {
                r = r.lowerBound..<min(r.upperBound, availableLength)
                handle.seek(toFileOffset: UInt64(r.lowerBound))
                body = handle.readData(ofLength: r.upperBound - r.lowerBound)
                header = "HTTP/1.1 206 Partial Content\r\n" +
                    "Content-Range: bytes \(r.lowerBound)-\(r.upperBound - 1)/\(completeLength)\r\n" +
                    "Content-Length: \(body.count)\r\n"
            } else {
                handle.seek(toFileOffset: 0)
                body = handle.readData(ofLength: availableLength)
                header = "HTTP/1.1 200 OK\r\nContent-Length: \(body.count)\r\n"
            }
        } else {
            header = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n"
        }
        let head = header +
            "Content-Type: video/mp4\r\nAccept-Ranges: bytes\r\nConnection: close\r\n\r\n"
        var resp = Data(head.utf8)
        resp.append(body)
        conn.send(content: resp, completion: .contentProcessed({ _ in conn.cancel() }))
    }
}
