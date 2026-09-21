import AppKit
import SwiftUI

enum ScreenshotRenderer {
    static var isActive: Bool {
        CommandLine.arguments.contains("--screenshot")
    }

    static var outputURL: URL {
        if let index = CommandLine.arguments.firstIndex(of: "--screenshot-output"),
           CommandLine.arguments.indices.contains(index + 1) {
            return URL(fileURLWithPath: CommandLine.arguments[index + 1])
        }
        return URL(fileURLWithPath: "docs/screenshot.png")
    }

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.appearance = NSAppearance(named: .darkAqua)
        let delegate = ScreenshotAppDelegate()
        ScreenshotAppDelegate.shared = delegate
        app.delegate = delegate
        app.run()
    }

    @MainActor
    static func run() {
        let player = FilePlayer(restoreSavedFile: false)
        let store = SourceStore.preview()
        let router = AudioRouter.preview(filePlayer: player)
        let root = ScreenshotView(store: store, router: router, filePlayer: player)

        let hosting = NSHostingView(rootView: root)
        hosting.wantsLayer = true
        hosting.layer?.isOpaque = false

        let width = EchoPanelLayout.width + 56
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: 480)

        let window = NSPanel(
            contentRect: hosting.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.becomesKeyOnlyIfNeeded = true
        window.identifier = NSUserInterfaceItemIdentifier("echo.screenshot")
        window.appearance = NSAppearance(named: .darkAqua)
        hosting.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        ScreenshotAppDelegate.shared?.window = window

        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            window.setFrameOrigin(NSPoint(x: visible.midX - width / 2, y: visible.midY - 240))
        }
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let fitting = hosting.fittingSize
            let size = NSSize(
                width: max(fitting.width, width),
                height: max(fitting.height, 120)
            )
            hosting.frame.size = size
            window.setContentSize(size)
            hosting.layoutSubtreeIfNeeded()
            write(hosting, to: outputURL)
        }
    }

    @MainActor
    private static func write(_ hosting: NSHostingView<ScreenshotView>, to url: URL) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            guard let image = bitmap(of: hosting), let png = pngData(from: image) else {
                throw ScreenshotError.captureFailed
            }
            try png.write(to: url)
            print("Wrote \(url.path)")
            NSApp.terminate(nil)
        } catch {
            fputs("Echo: screenshot failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    @MainActor
    private static func bitmap(of hosting: NSView) -> NSImage? {
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            return nil
        }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        bitmap.size = hosting.bounds.size
        let image = NSImage(size: hosting.bounds.size)
        image.addRepresentation(bitmap)
        return image
    }

    private static func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff)
        else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}

private final class ScreenshotAppDelegate: NSObject, NSApplicationDelegate {
    static var shared: ScreenshotAppDelegate?
    var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        ScreenshotRenderer.run()
    }
}

private enum ScreenshotError: LocalizedError {
    case captureFailed

    var errorDescription: String? {
        "Could not capture the panel."
    }
}

private struct ScreenshotView: View {
    @Bindable var store: SourceStore
    @Bindable var router: AudioRouter
    @Bindable var filePlayer: FilePlayer

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 36, height: 22)
                .background(.bar, in: Capsule())

            SourceListView(store: store, router: router, filePlayer: filePlayer)
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(nsColor: .windowBackgroundColor))
                }
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.regularMaterial)
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: .black.opacity(0.28), radius: 16, y: 8)
        }
        .padding(28)
        .fixedSize()
        .preferredColorScheme(.dark)
    }
}
