import Foundation
import Network

/// BitTorrent 客户端核心：协调 peers、从 magnet 获取种子元数据（ut_metadata）、
/// 按序流式下载所选视频并落盘，通过 LocalHTTPServer 提供边下边播。
@MainActor
final class TorrentClient {
    enum State: Equatable {
        case idle, resolvingPeers, fetchingMetadata, downloading, ready
        case failed(String), stopped
    }

    let magnet: MagnetLink
    private let peerId: Data
    let server = LocalHTTPServer(port: 8080)

    private(set) var state: State = .idle
    private(set) var meta: TorrentMeta?
    private(set) var displayName: String = ""
    private(set) var progress: Double = 0
    private(set) var fileURL: URL?
    private(set) var peerCount: Int = 0

    var onStateChange: ((State) -> Void)?
    var onProgress: ((Double) -> Void)?
    var onLog: ((String) -> Void)?

    private var peers: [PeerConnection] = []
    private var peerStates: [ObjectIdentifier: PeerState] = [:]

    // 元数据（magnet 模式）
    private var metaPieces: [Int: Data] = [:]
    private var metaTotalSize = 0
    private var metaPieceCount = 0
    private var requestedMetaPieces: Set<Int> = []

    // 下载
    private var selectedFile: TorrentFile?
    private var fileHandle: FileHandle?
    private var pieceLength = 0
    private var fileFirstPiece = 0
    private var fileLastPiece = 0
    private var pendingPieces: [Int] = []
    private var downloadedPieces: Set<Int> = []
    private var downloadedBytes = 0
    private var totalBytes = 0
    private var readySignaled = false

    private let writeQueue = DispatchQueue(label: "torrent.write")

    struct PeerState {
        var utMetaId: UInt8?
        var choked = true
        var inflight = Set<Int>()
    }

    init(magnet: MagnetLink) {
        self.magnet = magnet
        self.peerId = Self.makePeerId()
    }

    static func makePeerId() -> Data {
        var p = Data("-MP0100-".utf8)
        for _ in 0..<12 { p.append(UInt8.random(in: 0...255)) }
        return p
    }

    var playURL: URL? { URL(string: "http://127.0.0.1:\(server.port)/") }

    // MARK: - 启动
    func start() {
        setState(.resolvingPeers)
        log("解析 peers（tracker / x.pe / DHT）…")
        let lock = NSLock()
        var candidates: [(String, Int)] = []
        let add: ([(String, Int)]) -> Void = { list in
            lock.lock(); candidates.append(contentsOf: list); lock.unlock()
        }
        for pe in magnet.peerAddresses {
            let ps = pe.split(separator: ":")
            if ps.count == 2, let port = Int(ps[1]) { add([(String(ps[0]), port)]) }
        }
        let group = DispatchGroup()
        for tr in magnet.trackers {
            group.enter()
            TrackerClient(url: tr, infoHash: magnet.infoHash, peerId: peerId, port: 6881)
                .announce { peers, err in
                    if let peers { add(peers) }
                    if let err { Task { @MainActor in self.log("tracker \(tr.host ?? ""): \(err.localizedDescription)") } }
                    group.leave()
                }
        }
        group.enter()
        DHTClient(infoHash: magnet.infoHash, peerId: peerId).query { peers in
            add(peers)
            group.leave()
        }
        group.notify(queue: .main) { [weak self] in
            lock.lock(); let list = candidates; lock.unlock()
            self?.connectToPeers(list)
        }
    }

    private func connectToPeers(_ list: [(String, Int)]) {
        var seen = Set<String>()
        var uniq: [(String, Int)] = []
        for (h, p) in list where seen.insert("\(h):\(p)").inserted { uniq.append((h, p)) }
        log("找到 \(uniq.count) 个候选 peer，连接中…")
        let limited = Array(uniq.prefix(40))
        for (host, port) in limited {
            let peer = PeerConnection(host: host, port: port, infoHash: magnet.infoHash, peerId: peerId)
            peerStates[ObjectIdentifier(peer)] = PeerState()
            peer.onConnected = { [weak self] in self?.log("已连接 \(host):\(port)") }
            peer.onHandshake = { [weak self] in Task { @MainActor in self?.handleHandshake(peer) } }
            peer.onMessage = { [weak self] msg in Task { @MainActor in self?.handleMessage(peer, msg) } }
            peer.onDisconnect = { [weak self] in Task { @MainActor in self?.handleDisconnect(peer) } }
            peers.append(peer)
            peer.connect()
        }
        peerCount = peers.count
        if peers.isEmpty {
            setState(.failed("未找到可连接的 peer：磁力可能缺少 tracker，换带 tr= 的链接，或等待 DHT 节点响应"))
        }
    }

    // MARK: - 握手 / 扩展
    private func handleHandshake(_ peer: PeerConnection) {
        guard peerStates[ObjectIdentifier(peer)] != nil else { return }
        if state == .resolvingPeers { setState(.fetchingMetadata) }
        let dict: [String: Any] = ["m": ["ut_metadata": Int64(1), "ut_pex": Int64(1)]]
        peer.sendExtended(extId: 0, payload: BEncode.encode(dict))
        peer.sendInterested()
    }

    private func handleMessage(_ peer: PeerConnection, _ msg: PeerMessage) {
        let id = ObjectIdentifier(peer)
        guard peerStates[id] != nil else { return }
        switch msg {
        case .choke:
            if var st = peerStates[id] { st.choked = true; peerStates[id] = st }
        case .unchoke:
            if var st = peerStates[id] { st.choked = false; peerStates[id] = st }
            if state == .fetchingMetadata || state == .resolvingPeers { requestMetadata(from: peer) }
            else if state == .downloading { pumpRequests(peer) }
        case .have, .bitfield:
            break
        case .piece(let idx, let begin, let block):
            handlePiece(peer: peer, index: idx, begin: begin, block: block)
        case .extended(let extId, let payload):
            handleExtended(peer: peer, extId: extId, payload: payload)
        }
    }

    // MARK: - ut_metadata
    private func requestMetadata(from peer: PeerConnection) {
        guard let st = peerStates[ObjectIdentifier(peer)], let utId = st.utMetaId else { return }
        if metaPieceCount == 0 {
            requestMetaPiece(peer, utId: utId, piece: 0)
        } else {
            for k in 0..<metaPieceCount where !requestedMetaPieces.contains(k) {
                requestMetaPiece(peer, utId: utId, piece: k)
            }
        }
    }

    private func requestMetaPiece(_ peer: PeerConnection, utId: UInt8, piece k: Int) {
        guard requestedMetaPieces.insert(k).inserted else { return }
        let dict: [String: Any] = ["msg_type": Int64(0), "piece": Int64(k)]
        peer.sendExtended(extId: utId, payload: BEncode.encode(dict))
    }

    private func handleExtended(peer: PeerConnection, extId: UInt8, payload: Data) {
        let id = ObjectIdentifier(peer)
        if extId == 0 {
            guard let dict = try? BEncode.decode(payload) as? [String: Any],
                  let m = dict["m"] as? [String: Any],
                  let ut = m["ut_metadata"] as? Int64 else { return }
            let wasChoked: Bool
            if var st = peerStates[id] { st.utMetaId = UInt8(ut); wasChoked = st.choked; peerStates[id] = st }
            else { return }
            if !wasChoked { requestMetadata(from: peer) }
            return
        }
        guard let st = peerStates[id], let utId = st.utMetaId, extId == utId else { return }
        var pos = 0
        guard let (headerAny, end) = parseTopDict(payload, &pos),
              let header = headerAny as? [String: Any],
              let msgType = header["msg_type"] as? Int64, msgType == 1,
              let piece = header["piece"] as? Int64 else { return }
        let body = Data(payload[end...])
        metaPieces[Int(piece)] = body
        if let ts = header["total_size"] as? Int64, metaTotalSize == 0 {
            metaTotalSize = Int(ts)
            metaPieceCount = (metaTotalSize + 16383) / 16384
            log("元数据 \(metaTotalSize) 字节，共 \(metaPieceCount) 片")
            for p in peers where peerStates[ObjectIdentifier(p)]?.utMetaId != nil &&
                             peerStates[ObjectIdentifier(p)]?.choked == false {
                requestMetadata(from: p)
            }
        }
        checkMetadataComplete()
    }

    private func checkMetadataComplete() {
        guard metaTotalSize > 0, metaPieceCount > 0, metaPieces.count >= metaPieceCount else { return }
        var all = Data()
        for k in 0..<metaPieceCount { if let p = metaPieces[k] { all.append(p) } }
        all = Data(all.prefix(metaTotalSize))
        guard all.count >= metaTotalSize else { return }
        guard sha1(all) == magnet.infoHash else {
            log("元数据校验失败，重试")
            metaPieces.removeAll(); requestedMetaPieces.removeAll()
            metaTotalSize = 0; metaPieceCount = 0
            for p in peers where peerStates[ObjectIdentifier(p)]?.choked == false { requestMetadata(from: p) }
            return
        }
        guard let infoDict = try? BEncode.decode(all) as? [String: Any] else {
            setState(.failed("元数据解析失败")); return
        }
        do {
            let meta = try TorrentMeta.parse(infoDict: infoDict, infoHash: magnet.infoHash)
            self.meta = meta
            self.displayName = meta.name
            log("种子：\(meta.name)，\(meta.files.count) 文件，\(meta.totalLength) 字节")
            startDownloading(meta)
        } catch {
            setState(.failed("种子信息解析失败：\(error)"))
        }
    }

    // MARK: - 流式下载
    private func startDownloading(_ meta: TorrentMeta) {
        guard let file = meta.largestVideoFile ?? meta.files.max(by: { $0.length < $1.length }) else {
            setState(.failed("种子内无视频/文件")); return
        }
        selectedFile = file
        pieceLength = meta.pieceLength
        let fStart = file.offset
        let fEnd = file.offset + file.length
        fileFirstPiece = fStart / pieceLength
        fileLastPiece = (fEnd - 1) / pieceLength
        totalBytes = file.length
        pendingPieces = Array(fileFirstPiece...fileLastPiece)

        let dir = FileManager.default.temporaryDirectory
        let fname = (file.path as NSString).lastPathComponent
        let url = dir.appendingPathComponent(fname)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let fh = try? FileHandle(forWritingTo: url) else {
            setState(.failed("无法创建本地文件")); return
        }
        fh.truncateFile(atOffset: UInt64(file.length))
        fileHandle = fh
        fileURL = url
        server.fileURL = url
        server.completeLength = file.length
        server.availableLength = 0
        try? server.start()
        setState(.downloading)
        log("开始流式下载：\(fname)（\(file.length) 字节）")
        for p in peers where peerStates[ObjectIdentifier(p)]?.choked == false { pumpRequests(p) }
    }

    private func pumpRequests(_ peer: PeerConnection) {
        let id = ObjectIdentifier(peer)
        guard var st = peerStates[id] else { return }
        while st.inflight.count < 5, !pendingPieces.isEmpty {
            let idx = pendingPieces.removeFirst()
            st.inflight.insert(idx)
            peer.sendRequest(index: idx, begin: 0, length: pieceLength)
        }
        peerStates[id] = st
    }

    private func handlePiece(peer: PeerConnection, index: Int, begin: Int, block: Data) {
        let id = ObjectIdentifier(peer)
        if var st = peerStates[id] { st.inflight.remove(index); peerStates[id] = st }
        guard let file = selectedFile, let fh = fileHandle else { return }
        let globalOffset = index * pieceLength + begin
        let localOffset = globalOffset - file.offset
        guard localOffset >= 0, localOffset < file.length else { return }
        let writeLen = min(block.count, file.length - localOffset)
        guard writeLen > 0 else { return }
        writeQueue.async {
            fh.seek(toFileOffset: UInt64(localOffset))
            fh.write(Data(block.prefix(writeLen)))
        }
        downloadedPieces.insert(index)
        server.availableLength = min(file.length, max(server.availableLength, localOffset + writeLen))
        progress = totalBytes > 0 ? Double(server.availableLength) / Double(totalBytes) : 0
        onProgress?(progress)
        if !readySignaled, server.availableLength >= totalBytes {
            readySignaled = true
            setState(.ready)
        }
        if let st = peerStates[id], st.inflight.count < 5, !pendingPieces.isEmpty { pumpRequests(peer) }
    }

    private func handleDisconnect(_ peer: PeerConnection) {
        let id = ObjectIdentifier(peer)
        if let st = peerStates[id] {
            for idx in st.inflight { pendingPieces.append(idx) }
            peerStates[id] = PeerState()
        }
        peerCount = max(0, peerCount - 1)
    }

    // MARK: - 工具
    private func setState(_ s: State) { state = s; onStateChange?(s) }
    private func log(_ m: String) { onLog?(m); print("[torrent] \(m)") }

    func stop() {
        for p in peers { p.close() }
        peers.removeAll(); peerStates.removeAll()
        try? fileHandle?.close(); fileHandle = nil
        server.stop()
        setState(.stopped)
    }

    /// 解析 bencode 顶层 dict 并返回其结束位置（用于从 ut_metadata 消息分离 bencoded 头与二进制 body）
    private func parseTopDict(_ d: Data, _ pos: inout Int) -> (Any, Int)? {
        guard pos < d.count, d[pos] == UInt8(ascii: "d") else { return nil }
        let start = pos
        skipBValue(d, &pos)
        let dictData = Data(d[start..<pos])
        guard let dict = try? BEncode.decode(dictData) else { return nil }
        return (dict, pos)
    }

    private func skipBValue(_ d: Data, _ pos: inout Int) {
        guard pos < d.count else { return }
        let c = d[pos]
        if c == UInt8(ascii: "i") {
            if let e = d[pos..<d.count].firstIndex(of: UInt8(ascii: "e")) { pos = e + 1 }
            else { pos = d.count }
        } else if c == UInt8(ascii: "l") || c == UInt8(ascii: "d") {
            pos += 1
            while pos < d.count, d[pos] != UInt8(ascii: "e") { skipBValue(d, &pos) }
            if pos < d.count { pos += 1 }
        } else if (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(c) {
            guard let colon = d[pos..<d.count].firstIndex(of: UInt8(ascii: ":")) else { pos = d.count; return }
            let len = Int(String(data: Data(d[pos..<colon]), encoding: .ascii) ?? "0") ?? 0
            pos = colon + 1 + len
        } else { pos = d.count }
    }
}
