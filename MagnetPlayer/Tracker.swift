import Foundation

/// HTTP Tracker announce 客户端（compact=1 返回 6 字节/peer 二进制）。
struct TrackerClient {
    let url: URL
    let infoHash: Data
    let peerId: Data
    let port: UInt16

    func announce(completion: @escaping ([(String, Int)]?, Error?) -> Void) {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            completion(nil, TrackerError.badURL); return
        }
        let ih = infoHash.map { String(format: "%%%02x", $0) }.joined()
        let pid = peerId.map { String(format: "%%%02x", $0) }.joined()
        var q = comps.percentEncodedQuery ?? ""
        if !q.isEmpty { q += "&" }
        q += "info_hash=\(ih)&peer_id=\(pid)&port=\(port)"
        q += "&uploaded=0&downloaded=0&left=99999999999&compact=1&event=started&numwant=50"
        comps.percentEncodedQuery = q
        guard let u = comps.url else { completion(nil, TrackerError.badURL); return }

        var req = URLRequest(url: u)
        req.timeoutInterval = 15
        let task = URLSession.shared.dataTask(with: req) { data, _, err in
            if let err { completion(nil, err); return }
            guard let data else { completion(nil, TrackerError.noData); return }
            do {
                guard let dict = try BEncode.decode(data) as? [String: Any] else {
                    completion(nil, TrackerError.badResponse); return
                }
                var peers: [(String, Int)] = []
                if let p = dict["peers"] as? Data {
                    var i = 0
                    while i + 6 <= p.count {
                        let ip = "\(p[i]).\(p[i+1]).\(p[i+2]).\(p[i+3])"
                        let port = Int(p[i+4]) << 8 | Int(p[i+5])
                        peers.append((ip, port)); i += 6
                    }
                } else if let arr = dict["peers"] as? [[String: Any]] {
                    for d in arr {
                        if let ip = (d["ip"] as? Data).flatMap({ String(data: $0, encoding: .utf8) }),
                           let port = bInt(d["port"]) {
                            peers.append((ip, port))
                        }
                    }
                }
                completion(peers, nil)
            } catch {
                completion(nil, error)
            }
        }
        task.resume()
    }

    enum TrackerError: Error { case badURL, noData, badResponse }
}
