import SwiftUI
import AVKit

struct PlayerView: View {
    let url: URL
    @State private var player: AVPlayer

    init(url: URL) {
        self.url = url
        _player = State(initialValue: AVPlayer(url: url))
    }

    var body: some View {
        VideoPlayer(player: player)
            .edgesIgnoringSafeArea(.all)
            .onAppear { player.play() }
            .navigationBarTitleDisplayMode(.inline)
    }
}
