import Foundation
import Network

/// 极简 DHT 客户端：KRPC over UDP，向 bootstrap 节点发起 get_peers 迭代查询，
/// 收集 peers（values）与候选节点（nodes）。用于磁力链接没有 tracker 时寻找 peer。
final class DHTClient {
    let infoHash: Data
    let peerId: Data
    private let bootstrap: [(String, Int)] = [
        ("router.bittorrent.com", 6881),
        ("dht.transmissionbt.com", 6881),
        ("dht.ubuntu.com", 6881),
        ("router.utorrent.com", 6881)
    ]
    private let dhtQueue = DispatchQueue(label: "dht.client")
    private var foundPeers: [(String, Int)] = []
    private var queried = Set<String>()
    private var toQuery: [(String, Int)] = []
    private var inflight = 0
    private var finished = false
    private var tx: UInt16 = 0
    private var onDone: (([(String, Int)]) -> Void)?

    init(infoHash: Data, peerId: Data) {
        self.infoHash = infoHash
        self.peerId = peerId
    }

    func query(completion: @escaping ([(String, Int)]) -> Void) {
        onDone = completion
        toQuery = bootstrap
        dhtQueue.async { self.pump() }
        dhtQueue.asyncAfter(deadline: .now() + 5) { self.finish() }
    }

    private func nextTx() -> UInt16 { tx &+= 1; return tx }

    private func dequeue() -> (String, Int)? {
        while !toQuery.isEmpty {
            let n = toQuery.removeFirst()
            let key = "\(n.0):\(n.1)"
            if queried.contains(key) { continue }
            queried.insert(key)
            return n
        }
        return nil
    }

    private func pump() {
        while let node = dequeue() {
            guard inflight < 80 else { break }
            inflight += 1
            queryNode(node) { peers, nodes in
                self.dhtQueue.async {
                    self.foundPeers.append(contentsOf: peers)
                    for nn in nodes where !self.queried.contains("\(nn.0):\(nn.1)") {
                        self.toQuery.append(nn)
                    }
                    self.inflight -= 1
                    if self.toQuery.isEmpty, self.inflight == 0 { self.finish() }
                    else { self.pump() }
                }
            }
        }
        if inflight == 0, toQuery.isEmpty { finish() }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        var seen = Set<String>()
        var uniq: [(String, Int)] = []
        for p in foundPeers {
            let k = "\(p.0):\(p.1)"
            if seen.insert(k).inserted { uniq.append(p) }
        }
        onDone?(uniq)
        onDone = nil
    }

    private func queryNode(_ node: (String, Int), _ cb: @escaping ([(String, Int)], [(String, Int)]) -> Void) {
        let port = NWEndpoint.Port(rawValue: UInt16(node.1)) ?? NWEndpoint.Port(6881)
        let conn = NWConnection(host: NWEndpoint.Host(node.0), port: port, using: .udp)
        let myTx = nextTx()
        let req = BEncode.encode([
            "t": Data([UInt8((myTx >> 8) & 0xFF), UInt8(myTx & 0xFF)]),
            "y": "q",
            "q": "get_peers",
            "a": ["id": peerId, "info_hash": infoHash]
        ] as [String: Any])
        var done = false
        let once: ([(String, Int)], [(String, Int)]) -> Void = { p, n in
            guard !done else { return }
            done = true
            conn.cancel()
            cb(p, n)
        }
        conn.stateUpdateHandler = { st in
            switch st {
            case .ready:
                conn.send(content: req, completion: .idempotent)
                conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                    if let data { self.parseResponse(data, cb: once) } else { once([], []) }
                }
            case .failed, .cancelled:
                once([], [])
            default: break
            }
        }
        conn.start(queue: .global())
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { once([], []) }
    }

    private func parseResponse(_ data: Data, cb: @escaping ([(String, Int)], [(String, Int)]) -> Void) {
        guard let dict = try? BEncode.decode(data) as? [String: Any],
              let r = dict["r"] as? [String: Any] else { cb([], []); return }
        var peers: [(String, Int)] = []
        if let vals = r["values"] as? [Data] {
            for v in vals where v.count == 6 {
                let ip = "\(v[0]).\(v[1]).\(v[2]).\(v[3])"
                let port = Int(v[4]) << 8 | Int(v[5])
                peers.append((ip, port))
            }
        }
        var nodes: [(String, Int)] = []
        if let n = r["nodes"] as? Data {
            var i = 0
            while i + 26 <= n.count {
                let ip = "\(n[i+20]).\(n[i+21]).\(n[i+22]).\(n[i+23])"
                let port = Int(n[i+24]) << 8 | Int(n[i+25])
                nodes.append((ip, port)); i += 26
            }
        }
        cb(peers, nodes)
    }
}
