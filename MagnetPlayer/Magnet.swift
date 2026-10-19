import Foundation

enum MagnetError: Error { case invalid, noHash, badHash, noTrackers }

/// 解析 magnet:?xt=urn:btih:...&dn=...&tr=...&x.pe=...
struct MagnetLink {
    let infoHash: Data          // 20 字节 (SHA1)
    let displayName: String?
    let trackers: [URL]         // tr= 参数（去重、保留顺序）
    let peerAddresses: [String] // x.pe= 参数, 形如 "1.2.3.4:6881"

    static func parse(_ raw: String) throws -> MagnetLink {
        let str = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: str), url.scheme?.lowercased() == "magnet" else {
            throw MagnetError.invalid
        }
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = comps.queryItems else { throw MagnetError.invalid }

        guard let xt = items.first(where: { $0.name.lowercased() == "xt" })?.value,
              xt.lowercased().hasPrefix("urn:btih:") else { throw MagnetError.noHash }

        let hashStr = String(xt.dropFirst("urn:btih:".count))
        let infoHash = try decodeInfoHash(hashStr)

        let displayName = items.first(where: { $0.name.lowercased() == "dn" })?.value?
            .removingPercentEncoding

        var trackers: [URL] = []
        for tr in items.filter({ $0.name.lowercased() == "tr" }) {
            if let v = tr.value, let u = URL(string: v) { trackers.append(u) }
        }
        // 去重
        var seen = Set<String>()
        trackers = trackers.filter { seen.insert($0.absoluteString).inserted }

        let peerAddresses = items.filter { $0.name.lowercased() == "x.pe" }
            .compactMap { $0.value }

        return MagnetLink(infoHash: infoHash, displayName: displayName,
                          trackers: trackers, peerAddresses: peerAddresses)
    }

    private static func decodeInfoHash(_ s: String) throws -> Data {
        if s.count == 40 {
            var bytes = Data()
            var i = s.startIndex
            while i < s.endIndex {
                let j = s.index(i, offsetBy: 2, limitedBy: s.endIndex) ?? s.endIndex
                let hex = String(s[i..<j])
                guard let b = UInt8(hex, radix: 16) else { throw MagnetError.badHash }
                bytes.append(b)
                i = j
            }
            guard bytes.count == 20 else { throw MagnetError.badHash }
            return bytes
        } else if s.count == 32 {
            // Base32 (RFC4648, 大写, 无 padding)
            guard let d = base32Decode(s) else { throw MagnetError.badHash }
            return d
        } else {
            throw MagnetError.badHash
        }
    }

    // 简易 Base32 解码 (字母表 ABCDEFGHIJKLMNOPQRSTUVWXYZ234567)
    private static func base32Decode(_ s: String) -> Data? {
        let alpha = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".utf8)
        var bits = 0
        var value = 0
        var out = Data()
        for ch in s.uppercased() where !ch.isWhitespace {
            guard let idx = alpha.firstIndex(of: UInt8(ascii: ch)) else { return nil }
            value = (value << 5) | Int(idx)
            bits += 5
            if bits >= 8 {
                bits -= 8
                out.append(UInt8((value >> bits) & 0xFF))
            }
        }
        return out
    }
}
