import SwiftUI

struct ContentView: View {
    @State private var magnet = ""
    @State private var loading = false
    @State private var message: String?
    @State private var parseResult: ParseResult?
    @State private var showSettings = false
    @State private var playURL: URL?

    var body: some View {
        NavigationView {
            VStack(spacing: 16) {
                HStack {
                    Text("服务器：\(Config.serverURL)")
                        .font(.caption)
                        .foregroundColor(.gray)
                        .lineLimit(1)
                    Spacer()
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
                .padding(.horizontal)

                TextField("粘贴磁力链接 magnet:?xt=urn:btih:...", text: $magnet)
                    .textFieldStyle(.roundedBorder)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .padding(.horizontal)

                Button {
                    parse()
                } label: {
                    if loading {
                        ProgressView()
                    } else {
                        Text("解析磁力")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(magnet.trimmingCharacters(in: .whitespaces).isEmpty || loading)
                .padding(.horizontal)

                if let m = message {
                    Text(m)
                        .font(.caption)
                        .foregroundColor(.red)
                        .padding(.horizontal)
                }

                if let result = parseResult {
                    List {
                        Section("\(result.name)（共 \(result.files.count) 个文件）") {
                            ForEach(result.files) { f in
                                Button {
                                    play(f)
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(f.name)
                                                .font(.system(size: 14))
                                                .lineLimit(1)
                                            Text(Self.formatSize(f.size))
                                                .font(.caption)
                                                .foregroundColor(.gray)
                                        }
                                        Spacer()
                                        Image(systemName: "play.circle")
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                } else {
                    Spacer()
                    Text("输入磁力链接，解析后选择要播放的视频文件")
                        .font(.caption)
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.center)
                        .padding()
                    Spacer()
                }
            }
            .navigationTitle("磁力播放器")
            .sheet(isPresented: $showSettings) { SettingsView() }
            .fullScreenCover(item: $playURL) { url in
                PlayerView(url: url)
                    .ignoresSafeArea()
            }
        }
    }

    static func formatSize(_ b: Int64) -> String {
        let kb = 1024.0, mb = kb * 1024, gb = mb * 1024
        let v = Double(b)
        if v >= gb { return String(format: "%.2f GB", v / gb) }
        if v >= mb { return String(format: "%.1f MB", v / mb) }
        if v >= kb { return String(format: "%.0f KB", v / kb) }
        return "\(b) B"
    }

    private func parse() {
        let m = magnet.trimmingCharacters(in: .whitespaces)
        guard !m.isEmpty else { return }
        loading = true
        message = nil
        parseResult = nil
        Task {
            do {
                parseResult = try await APIClient.shared.parse(magnet: m)
            } catch {
                message = error.localizedDescription
            }
            loading = false
        }
    }

    private func play(_ f: FileItem) {
        let m = magnet.trimmingCharacters(in: .whitespaces)
        loading = true
        message = nil
        Task {
            do {
                let s = try await APIClient.shared.stream(magnet: m, index: f.index)
                let full: String
                if s.hlsURL.hasPrefix("http") {
                    full = s.hlsURL
                } else if s.hlsURL.hasPrefix("/") {
                    full = Config.serverURL + s.hlsURL
                } else {
                    full = Config.serverURL + "/" + s.hlsURL
                }
                guard let u = URL(string: full) else {
                    message = "后端返回的播放地址无效"
                    loading = false
                    return
                }
                playURL = u
            } catch {
                message = error.localizedDescription
            }
            loading = false
        }
    }
}

extension URL: Identifiable {
    public var id: String { absoluteString }
}