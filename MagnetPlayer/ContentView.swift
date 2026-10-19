import SwiftUI
import AVKit

struct ContentView: View {
    @EnvironmentObject var manager: TorrentManager
    @State private var magnetText = ""
    @State private var showPlayer = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.blue)
                Text("磁力播放器").font(.title.bold())
                Text("iOS 16 · 边下边播").font(.caption).foregroundStyle(.secondary)

                TextField("粘贴磁力链接 magnet:?xt=urn:btih:…", text: $magnetText)
                    .textFieldStyle(.roundedBorder)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .padding(.horizontal)

                Button { manager.loadMagnet(magnetText) } label: {
                    Label("开始播放", systemImage: "bolt.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(magnetText.trimmingCharacters(in: .whitespaces).isEmpty)

                Divider()

                HStack {
                    Text("状态").bold()
                    Spacer()
                    Text(manager.statusText)
                        .foregroundStyle(manager.statusText.contains("失败") ? .red : .primary)
                }
                .padding(.horizontal)

                if !manager.name.isEmpty {
                    HStack {
                        Text("种子").bold()
                        Spacer()
                        Text(manager.name).lineLimit(1)
                    }
                    .padding(.horizontal)
                }

                ProgressView(value: manager.progress) {
                    EmptyView()
                } currentValueLabel: {
                    Text("\(Int(manager.progress * 100))%")
                }
                .padding(.horizontal)

                if manager.readyToPlay {
                    Button { showPlayer = true } label: {
                        Label("▶ 播放视频", systemImage: "play.fill")
                    }
                    .buttonStyle(.bordered)
                }

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(manager.logLines, id: \.self) { line in
                            Text(line).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal)
            }
            .padding(.vertical)
            .navigationTitle("MagnetPlayer")
            .navigationDestination(isPresented: $showPlayer) {
                if let url = manager.playURL { PlayerView(url: url) }
            }
        }
    }
}
