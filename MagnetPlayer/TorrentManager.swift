import Foundation
import SwiftUI

/// UI 与下载引擎之间的单例桥接。
@MainActor
final class TorrentManager: ObservableObject {
    static let shared = TorrentManager()

    @Published var statusText = "空闲"
    @Published var progress: Double = 0
    @Published var logLines: [String] = []
    @Published var readyToPlay = false
    @Published var name = ""

    var playURL: URL? { current?.playURL }

    private var current: TorrentClient?

    func loadMagnet(_ raw: String) {
        stop()
        do {
            let magnet = try MagnetLink.parse(raw)
            let short = magnet.infoHash.prefix(4).map { String(format: "%02x", $0) }.joined()
            let client = TorrentClient(magnet: magnet)
            current = client
            client.onStateChange = { [weak self] s in self?.applyState(s) }
            client.onProgress = { [weak self] p in self?.progress = p }
            client.onLog = { [weak self] m in self?.appendLog(m) }
            statusText = "解析中…"
            progress = 0
            readyToPlay = false
            appendLog("添加磁力：\(magnet.displayName ?? short)  [\(short)…]")
            client.start()
        } catch {
            statusText = "磁力解析失败"
            appendLog("磁力解析失败：\(error)")
        }
    }

    private func applyState(_ s: TorrentClient.State) {
        switch s {
        case .idle: statusText = "空闲"
        case .resolvingPeers: statusText = "解析 peer 中…"
        case .fetchingMetadata: statusText = "获取种子信息中…"
        case .downloading:
            statusText = "下载中（边下边播）"
        case .ready:
            statusText = "可播放 ✓"
            readyToPlay = true
        case .failed(let e):
            statusText = "失败"
            appendLog("失败：\(e)")
        case .stopped:
            statusText = "已停止"
        }
        name = current?.displayName ?? ""
    }

    func appendLog(_ m: String) {
        logLines.append(m)
        if logLines.count > 200 { logLines.removeFirst() }
    }

    func stop() {
        current?.stop()
        current = nil
    }
}
