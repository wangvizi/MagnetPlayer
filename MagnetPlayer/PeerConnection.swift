import Foundation
import Network

/// 大端 32 位读写
fileprivate func be32(_ d: Data, _ o: Int) -> Int {
    return (Int(d[o]) << 24) | (Int(d[o + 1]) << 16) | (Int(d[o + 2]) << 8) | Int(d[o + 3])
}
fileprivate func be32bytes(_ v: Int) -> [UInt8] {
    return [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF),
            UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
}

/// peer wire 消息
enum PeerMessage {
    case choke
    case unchoke
    case have(Int)
    case bitfield(Data)
    case piece(index: Int, begin: Int, block: Data)
    case extended(extId: UInt8, payload: Data)
}

/// 单个 BitTorrent peer 的 TCP 连接：握手 + 消息收发（纯 Network.framework）。
final class PeerConnection {
    let host: String
    let port: Int
    let infoHash: Data
    let peerId: Data

    var onConnected: (() -> Void)?
    var onHandshake: (() -> Void)?
    var onMessage: ((PeerMessage) -> Void)?
    var onDisconnect: (() -> Void)?

    private var conn: NWConnection?
    private var buffer = Data()
    private var handshakeSent = false
    private var handshakeReceived = false
    private var alive = true

    init(host: String, port: Int, infoHash: Data, peerId: Data) {
        self.host = host; self.port = port
        self.infoHash = infoHash; self.peerId = peerId
    }

    func connect() {
        let nwport = NWEndpoint.Port(rawValue: UInt16(port)) ?? NWEndpoint.Port(6881)
        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwport, using: .tcp)
        self.conn = conn
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.onConnected?()
                self.sendHandshake()
                self.receiveLoop()
            case .failed, .cancelled:
                self.alive = false
                self.onDisconnect?()
            default: break
            }
        }
        conn.start(queue: .global())
    }

    private func sendHandshake() {
        guard !handshakeSent else { return }
        handshakeSent = true
        let pstr = "BitTorrent protocol"
        var hs = Data()
        hs.append(UInt8(pstr.utf8.count))
        hs.append(contentsOf: pstr.utf8)
        var reserved = Data(count: 8)
        reserved[5] |= 0x10   // BEP10 扩展协议
        reserved[7] |= 0x01   // fast extension
        hs.append(reserved)
        hs.append(infoHash)
        hs.append(peerId)
        conn?.send(content: hs, completion: .idempotent)
    }

    private func receiveLoop() {
        conn?.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, err in
            guard let self, self.alive else { return }
            if let err { self.close(); return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.process()
            }
            if isComplete { self.close(); return }
            self.receiveLoop()
        }
    }

    private func process() {
        if !handshakeReceived {
            guard buffer.count >= 68 else { return }
            let pstrLen = Int(buffer[0])
            guard pstrLen == 19,
                  String(data: Data(buffer[1..<20]), encoding: .ascii) == "BitTorrent protocol" else {
                close(); return
            }
            buffer.removeFirst(68)
            handshakeReceived = true
            onHandshake?()
            process()
            return
        }
        while buffer.count >= 4 {
            let len = be32(buffer, 0)
            if len == 0 { buffer.removeFirst(4); continue }
            guard buffer.count >= 4 + len else { break }
            let id = buffer[4]
            let payload = Data(buffer[5..<4 + len])
            buffer.removeFirst(4 + len)
            switch id {
            case 0: onMessage?(.choke)
            case 1: onMessage?(.unchoke)
            case 4: guard payload.count >= 4 else { return }
                onMessage?(.have(be32(payload, 0)))
            case 5: onMessage?(.bitfield(payload))
            case 7: guard payload.count >= 8 else { return }
                onMessage?(.piece(index: be32(payload, 0), begin: be32(payload, 4),
                                 block: Data(payload[8...])))
            case 20: guard !payload.isEmpty else { return }
                onMessage?(.extended(extId: payload[0], payload: Data(payload[1...])))
            default: break
            }
        }
    }

    // MARK: - 发送
    func sendInterested() { sendMessage(id: 2, payload: Data()) }
    func sendUnchoke()    { sendMessage(id: 1, payload: Data()) }
    func sendNotInterested() { sendMessage(id: 3, payload: Data()) }

    func sendHave(_ index: Int) {
        var p = Data(); p.append(contentsOf: be32bytes(index)); sendMessage(id: 4, payload: p)
    }
    func sendRequest(index: Int, begin: Int, length: Int) {
        var p = Data()
        p.append(contentsOf: be32bytes(index))
        p.append(contentsOf: be32bytes(begin))
        p.append(contentsOf: be32bytes(length))
        sendMessage(id: 6, payload: p)
    }
    func sendCancel(index: Int, begin: Int, length: Int) {
        var p = Data()
        p.append(contentsOf: be32bytes(index))
        p.append(contentsOf: be32bytes(begin))
        p.append(contentsOf: be32bytes(length))
        sendMessage(id: 8, payload: p)
    }
    func sendExtended(extId: UInt8, payload: Data) {
        var p = Data(); p.append(extId); p.append(payload)
        sendMessage(id: 20, payload: p)
    }

    private func sendMessage(id: UInt8, payload: Data) {
        var msg = Data()
        msg.append(contentsOf: be32bytes(1 + payload.count))
        msg.append(id)
        msg.append(payload)
        conn?.send(content: msg, completion: .idempotent)
    }

    func close() {
        guard alive else { return }
        alive = false
        conn?.cancel()
        conn = nil
        onDisconnect?()
    }
}
