import Foundation
import CommonCrypto

enum TorrentMetaError: Error { case invalid, badInfoHash, noFiles }

/// 解析后的种子元信息（由 ut_metadata 得到的 info dict 构建）。
struct TorrentFile {
    let path: String
    let length: Int
    let offset: Int          // 在完整 torrent 数据流中的字节偏移（单文件模式直接用）
    var isVideo: Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return ["mp4", "mkv", "mov", "avi", "m4v", "webm", "flv", "ts", "wmv"].contains(ext)
    }
}

struct TorrentMeta {
    let infoHash: Data
    let name: String
    let pieceLength: Int
    let pieces: [Data]       // 每个 20 字节
    let files: [TorrentFile]
    let totalLength: Int
    let pieceCount: Int

    var largestVideoFile: TorrentFile? {
        files.filter { $0.isVideo }.max(by: { $0.length < $1.length })
    }

    /// 返回某个 piece index 覆盖的字节范围（clamped 到 totalLength）
    func rangeOfPiece(_ index: Int) -> Range<Int> {
        let start = index * pieceLength
        let end = min(start + pieceLength, totalLength)
        return start..<end
    }

    /// 给定全局字节偏移与长度，返回覆盖的 piece index 列表
    func pieceIndexesForRange(_ range: Range<Int>) -> [Int] {
        guard range.lowerBound < totalLength else { return [] }
        let first = range.lowerBound / pieceLength
        let last = (min(range.upperBound, totalLength) - 1) / pieceLength
        return (first...last).map { $0 }
    }

    static func parse(infoDict: [String: Any], infoHash: Data) throws -> TorrentMeta {
        guard let pieceLength = bInt(infoDict["piece length"]) else {
            throw TorrentMetaError.invalid
        }
        guard let piecesData = infoDict["pieces"] as? Data, piecesData.count % 20 == 0 else {
            throw TorrentMetaError.invalid
        }
        var pieces: [Data] = []
        var i = 0
        while i + 20 <= piecesData.count {
            pieces.append(Data(piecesData[i..<i + 20]))
            i += 20
        }

        let name: String
        if let nd = infoDict["name"] as? Data, let ns = String(data: nd, encoding: .utf8) {
            name = ns
        } else if let ns = infoDict["name"] as? String {
            name = ns
        } else {
            name = "torrent"
        }

        var files: [TorrentFile] = []
        var offset = 0
        if let filesArr = infoDict["files"] as? [[String: Any]] {
            for f in filesArr {
                let length = bInt(f["length"]) ?? 0
                let comps = (f["path"] as? [Data] ?? []).compactMap { String(data: $0, encoding: .utf8) }
                let path = comps.isEmpty ? "file" : comps.joined(separator: "/")
                files.append(TorrentFile(path: path, length: length, offset: offset))
                offset += length
            }
        } else if let length = bInt(infoDict["length"]) {
            files.append(TorrentFile(path: name, length: length, offset: 0))
        } else {
            throw TorrentMetaError.noFiles
        }

        let total = files.reduce(0) { $0 + $1.length }
        return TorrentMeta(infoHash: infoHash, name: name, pieceLength: pieceLength,
                           pieces: pieces, files: files, totalLength: total, pieceCount: pieces.count)
    }
}

/// 计算一个 bencode dict（已经过 BEncode 编码的 info bytes）的 SHA1
func sha1(_ data: Data) -> Data {
    var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
    data.withUnsafeBytes { buf in
        CC_SHA1(buf.baseAddress, CC_LONG(data.count), &digest)
    }
    return Data(digest)
}
