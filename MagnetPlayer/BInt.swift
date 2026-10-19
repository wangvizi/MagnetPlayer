import Foundation

/// 从 bencode 整数（Int64）或 NSNumber 安全地取 Int。
func bInt(_ v: Any?) -> Int? {
    if let i = v as? Int64 { return Int(i) }
    if let n = v as? NSNumber { return n.intValue }
    return nil
}
