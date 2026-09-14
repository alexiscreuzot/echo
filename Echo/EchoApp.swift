import AppKit
import SwiftUI

@main
struct EchoApp: App {
    @State private var store = SourceStore()
    @State private var router = AudioRouter()

    var body: some Scene {
        Window("Echo", id: "main") {
            SourceListView(store: store, router: router)
                .containerBackground(.clear, for: .window)
                .background(TransparentWindowBackground())
                .background(.ultraThinMaterial)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.automatic)
        .windowBackgroundDragBehavior(.enabled)
        .defaultSize(width: 360, height: 280)
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
        window.isMovableByWindowBackground = true
        window.hasShadow = true
        window.invalidateShadow()
    }
}
