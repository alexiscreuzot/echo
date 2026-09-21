import AppKit
import SwiftUI

enum EchoPanelLayout {
    static let width: CGFloat = 280
    static let pickerHeight: CGFloat = 360
    static let resizeDuration: TimeInterval = 0.25
}

struct EchoApp: App {
    @State private var store = SourceStore()
    @State private var filePlayer: FilePlayer
    @State private var router: AudioRouter

    init() {
        let player = FilePlayer()
        _filePlayer = State(initialValue: player)
        _router = State(initialValue: AudioRouter(filePlayer: player))
        DispatchQueue.main.async {
            Self.applyDockIcon()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            SourceListView(store: store, router: router, filePlayer: filePlayer)
        } label: {
            Image(systemName: router.isRunning ? "waveform.circle.fill" : "waveform")
                .accessibilityLabel("Echo")
        }
        .menuBarExtraStyle(.window)
    }

    private static func applyDockIcon() {
        let icon = Bundle.main.url(forResource: "AppIcon", withExtension: "icns")
            .flatMap { NSImage(contentsOf: $0) }
            ?? NSImage(named: "AppIcon")
        guard let icon else { return }
        NSApplication.shared.applicationIconImage = icon
    }
}
