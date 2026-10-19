import Foundation

enum BEncodeError: Error { case invalid, truncated }

/// 极简 Bencode 编解码（用于解析 Tracker 响应 / peer wire / ut_metadata）。
/// 约定：bencode 整数统一以 Int64 承载；dict key 按原始字节升序（info dict 算 SHA1 需要）。
enum BEncode {

    // MARK: - 解码
    static func decode(_ data: Data) throws -> Any {
        var pos = 0
        let v = try decodeOne(&pos, data: data)
        // 允许尾部多余字节（某些实现会附加额外数据），但主体必须解析完
        if pos != data.count && data.count - pos > 0 && data[pos] == 0 {
            // 忽略结尾的 0 填充
        }
        return v
    }

    private static func decodeOne(_ pos: inout Int, data: Data) throws -> Any {
        guard pos < data.count else { throw BEncodeError.truncated }
        let c = data[pos]
        if c == UInt8(ascii: "i") {
            pos += 1
            guard let end = data[pos..<data.count].firstIndex(of: UInt8(ascii: "e")) else { throw BEncodeError.invalid }
            let numData = data[pos..<end]
            guard let s = String(data: Data(numData), encoding: .ascii),
                  let v = Int64(s) else { throw BEncodeError.invalid }
            pos = end + 1
            return v
        } else if c == UInt8(ascii: "l") {
            pos += 1
            var arr: [Any] = []
            while pos < data.count && data[pos] != UInt8(ascii: "e") {
                arr.append(try decodeOne(&pos, data: data))
            }
            guard pos < data.count else { throw BEncodeError.truncated }
            pos += 1
            return arr
        } else if c == UInt8(ascii: "d") {
            pos += 1
            var dict: [String: Any] = [:]
            while pos < data.count && data[pos] != UInt8(ascii: "e") {
                let rawKey = try decodeOne(&pos, data: data)
                guard let k = rawKey as? Data else { throw BEncodeError.invalid }
                guard let keyStr = String(data: k, encoding: .utf8) else { throw BEncodeError.invalid }
                let val = try decodeOne(&pos, data: data)
                dict[keyStr] = val
            }
            guard pos < data.count else { throw BEncodeError.truncated }
            pos += 1
            return dict
        } else if c >= UInt8(ascii: "0") && c <= UInt8(ascii: "9") {
            // 字符串: <len>:
            guard let colon = data[pos..<data.count].firstIndex(of: UInt8(ascii: ":")) else { throw BEncodeError.invalid }
            let lenStr = String(data: Data(data[pos..<colon]), encoding: .ascii) ?? ""
            guard let len = Int(lenStr) else { throw BEncodeError.invalid }
            let start = colon + 1
            let end = start + len
            guard end <= data.count else { throw BEncodeError.truncated }
            let strData = Data(data[start..<end])
            pos = end
            return strData
        } else {
            throw BEncodeError.invalid
        }
    }

    // MARK: - 编码
    static func encode(_ value: Any) -> Data {
        var out = Data()
        encodeValue(value, into: &out)
        return out
    }

    private static func encodeValue(_ v: Any, into out: inout Data) {
        switch v {
        case let i as Int64:
            out.append(contentsOf: Array("i\(i)e".utf8))
        case let i as Int:
            out.append(contentsOf: Array("i\(i)e".utf8))
        case let d as Data:
            out.append(contentsOf: Array("\(d.count):".utf8))
            out.append(d)
        case let s as String:
            let sd = Data(s.utf8)
            out.append(contentsOf: Array("\(sd.count):".utf8))
            out.append(sd)
        case let arr as [Any]:
            out.append(UInt8(ascii: "l"))
            for e in arr { encodeValue(e, into: &out) }
            out.append(UInt8(ascii: "e"))
        case let dict as [String: Any]:
            out.append(UInt8(ascii: "d"))
            for (k, val) in dict.sorted(by: { $0.key < $1.key }) {
                let kd = Data(k.utf8)
                out.append(contentsOf: Array("\(kd.count):".utf8))
                out.append(kd)
                encodeValue(val, into: &out)
            }
            out.append(UInt8(ascii: "e"))
        default:
            break
        }
    }
}
