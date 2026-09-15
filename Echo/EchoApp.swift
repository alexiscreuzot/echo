import AppKit
import SwiftUI

enum EchoWindowLayout {
    static let defaultWidth: CGFloat = 360
    /// Window buttons, how-it-works, two source rows (58pt card + 8pt gap), and the action bar.
    static let defaultHeight: CGFloat = 320
    static let minHeight: CGFloat = 280
}

@main
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
        Window("Echo", id: "main") {
            SourceListView(store: store, router: router, filePlayer: filePlayer)
                .containerBackground(.clear, for: .window)
                .background(TransparentWindowBackground())
                .background(.ultraThinMaterial)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.automatic)
        .windowBackgroundDragBehavior(.enabled)
        .defaultSize(width: EchoWindowLayout.defaultWidth, height: EchoWindowLayout.defaultHeight)
    }

    private static func applyDockIcon() {
        let icon = Bundle.main.url(forResource: "AppIcon", withExtension: "icns")
            .flatMap { NSImage(contentsOf: $0) }
            ?? NSImage(named: "AppIcon")
        guard let icon else { return }
        NSApplication.shared.applicationIconImage = icon
    }
}

private struct TransparentWindowBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        WindowConfiguratorView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class WindowConfiguratorView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configure()
    }

    private func configure() {
        guard let window else { return }
        window.isOpaque = false
        window.backgroundColor = .clear
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = true
        window.hasShadow = true
        window.invalidateShadow()
    }
}
