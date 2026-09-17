import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SourceListView: View {
    @Bindable var store: SourceStore
    @Bindable var router: AudioRouter
    @Bindable var filePlayer: FilePlayer
    @State private var showingPicker = false
    @State private var confirmingQuit = false
    @State private var quitResetTask: Task<Void, Never>?
    @State private var panel: NSWindow?
    @State private var contentHeight: CGFloat = 0
    @State private var panelHeight: CGFloat = 0
    @State private var pendingFileURL: URL?

    var body: some View {
        Group {
            if showingPicker {
                AppPickerView(store: store) {
                    showingPicker = false
                }
            } else {
                mainContent
            }
        }
        .frame(
            width: EchoPanelLayout.width,
            height: panelHeight > 0 ? panelHeight : nil,
            alignment: .top
        )
        .clipped()
        .background(WindowAccessor { panel = $0 })
        .onChange(of: showingPicker) { _, isShowing in
            updatePanelHeight(
                isShowing ? EchoPanelLayout.pickerHeight : contentHeight,
                animated: true
            )
        }
        .onChange(of: contentHeight) { _, height in
            guard !showingPicker else { return }
            updatePanelHeight(height, animated: panelHeight > 0)
        }
        .onAppear {
            store.refreshProcessObjects()
            if let url = pendingFileURL {
                pendingFileURL = nil
                panelHeight = 0
                addAudioFile(url)
            }
        }
        .task {
            await router.prepareDevice()
        }
        .onChange(of: store.sources) { _, newSources in
            router.sync(sources: newSources)
        }
        .onChange(of: filePlayer.fileName) { _, _ in
            router.refreshFileStatus()
        }
        .onChange(of: filePlayer.loadError) { _, error in
            if let error {
                router.report(error)
            }
        }
    }

    private var mainContent: some View {
        VStack(spacing: 0) {
            statusBar
            sourceList
            addBar
            OutputMeter(level: outputLevel)
        }
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height in
            contentHeight = height
        }
    }

    private var hasContent: Bool {
        !store.sources.isEmpty || filePlayer.fileName != nil
    }

    private var canStart: Bool {
        store.sources.contains(where: \.enabled) || filePlayer.fileName != nil
    }

    private var outputLevel: Float {
        guard router.isRunning else { return 0 }
        return router.levels.values.max() ?? 0
    }

    private var sourceList: some View {
        Group {
            if !hasContent {
                emptyHero
            } else {
                VStack(spacing: 8) {
                    GlassEffectContainer(spacing: 8) {
                        VStack(spacing: 8) {
                            if filePlayer.fileName != nil {
                                PlayerCard(player: filePlayer, isRunning: router.isRunning) {
                                    withAnimation(.snappy(duration: 0.25)) {
                                        filePlayer.clear()
                                        router.refreshFileStatus()
                                    }
                                }
                                .transition(.asymmetric(insertion: .opacity, removal: .identity))
                            }
                            ForEach(store.sources) { source in
                                SourceRow(source: source) {
                                    store.toggle(source)
                                } onMute: {
                                    store.toggleMute(source)
                                } onRemove: {
                                    withAnimation(.snappy(duration: 0.25)) {
                                        store.remove(id: source.bundleID)
                                    }
                                }
                                .transition(.asymmetric(insertion: .opacity, removal: .identity))
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 2)
                .padding(.bottom, 16)
            }
        }
    }

    private var emptyHero: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                VStack(spacing: 8) {
                    sourceChip("App", systemImage: "speaker.wave.2.fill") {
                        showingPicker = true
                    }
                    sourceChip("File", systemImage: "doc.fill") {
                        importAudioFile()
                    }
                }
                MergeArrow()
                    .frame(width: 28, height: 52)
                Label("Echo", systemImage: "waveform")
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .glassEffect(.regular, in: .rect(cornerRadius: 12, style: .continuous))
            }
            .shadow(color: .black.opacity(0.28), radius: 8, y: 1)

            Text("Echo appears as a microphone in other apps.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 6)
    }

    private func sourceChip(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.callout.weight(.medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(width: 88)
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 12, style: .continuous))
        .help(title == "App" ? "Add an app" : "Add an audio file")
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "circle.fill")
                    .font(.system(size: 7))
                    .foregroundStyle(router.isRunning ? .green : .secondary.opacity(0.45))
                    .symbolEffect(.pulse, options: .repeating, isActive: router.isRunning)
                Text(router.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(router.status)
            }
            .layoutPriority(1)

            Spacer(minLength: 8)

            Button {
                if confirmingQuit {
                    NSApplication.shared.terminate(nil)
                } else {
                    confirmingQuit = true
                    quitResetTask?.cancel()
                    quitResetTask = Task { @MainActor in
                        try? await Task.sleep(for: .seconds(3))
                        guard !Task.isCancelled else { return }
                        confirmingQuit = false
                    }
                }
            } label: {
                Image(systemName: confirmingQuit ? "checkmark" : "power")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(confirmingQuit ? .red : .secondary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .help(confirmingQuit ? "Click again to quit" : "Quit Echo")
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    private var addBar: some View {
        HStack(spacing: 8) {
            Button {
                importAudioFile()
            } label: {
                Image(systemName: "waveform")
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.glass)
            .help(filePlayer.fileName == nil ? "Add an audio file" : "Replace audio file")

            Button {
                showingPicker = true
            } label: {
                Image(systemName: "plus")
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.glass)
            .help("Add an app")

            Spacer(minLength: 8)

            Button {
                if router.isRunning {
                    router.stop()
                } else {
                    store.refreshProcessObjects()
                    router.start(sources: store.sources)
                }
            } label: {
                Image(systemName: router.isRunning ? "stop.fill" : "play.fill")
                    .frame(width: 18, height: 18)
                    .offset(x: router.isRunning ? 0 : 0.5)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .tint(router.isRunning ? .red : .accentColor)
            .keyboardShortcut(.space, modifiers: [])
            .disabled(!router.isRunning && !canStart)
            .help(router.isRunning ? "Stop" : "Start")
            .accessibilityLabel(router.isRunning ? "Stop" : "Start")
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 10)
        .background(Color.secondary.opacity(0.08))
        .overlay(alignment: .top) {
            Divider()
                .opacity(0.5)
        }
    }

    private func importAudioFile() {
        let picker = NSOpenPanel()
        picker.allowedContentTypes = [.audio]
        picker.allowsMultipleSelection = false
        picker.canChooseDirectories = false

        NSApp.activate(ignoringOtherApps: true)
        picker.begin { response in
            guard response == .OK, let url = picker.url else { return }
            pendingFileURL = url
            reopenMenuBarExtra()
        }
    }

    private func addAudioFile(_ url: URL) {
        withAnimation(.snappy(duration: 0.3)) {
            filePlayer.load(url: url)
        }
        if router.isRunning {
            filePlayer.play()
        }
    }

    private func reopenMenuBarExtra() {
        if panel?.isVisible == true, let url = pendingFileURL {
            pendingFileURL = nil
            addAudioFile(url)
            return
        }
        clickEchoStatusItem()
    }

    private func clickEchoStatusItem() {
        for window in NSApp.windows where window.className.contains("NSStatusBar") {
            if let button = echoStatusButton(in: window.contentView) {
                button.performClick(nil)
                return
            }
        }
    }

    private func echoStatusButton(in view: NSView?) -> NSStatusBarButton? {
        guard let view else { return nil }
        if let button = view as? NSStatusBarButton {
            return button
        }
        for subview in view.subviews {
            if let button = echoStatusButton(in: subview) {
                return button
            }
        }
        return nil
    }

    private func updatePanelHeight(_ height: CGFloat, animated: Bool) {
        guard height > 0 else { return }
        let shouldAnimate = animated && panelHeight > 0
        if shouldAnimate {
            withAnimation(.snappy(duration: EchoPanelLayout.resizeDuration)) {
                panelHeight = height
            }
        } else {
            panelHeight = height
        }
        applyPanelHeight(height, animated: shouldAnimate)
    }

    /// A menu bar panel grows to fit its content but never shrinks back on its own,
    /// so the taller picker leaves the panel oversized once the list returns.
    private func applyPanelHeight(_ height: CGFloat, animated: Bool) {
        guard let panel, height > 0 else { return }
        let target = panel.frameRect(forContentRect: NSRect(x: 0, y: 0, width: panel.frame.width, height: height))
        guard abs(panel.frame.height - target.height) > 0.5 else { return }
        var frame = panel.frame
        frame.origin.y += frame.height - target.height
        frame.size.height = target.height
        guard animated else {
            panel.setFrame(frame, display: true)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = EchoPanelLayout.resizeDuration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
            panel.animator().setFrame(frame, display: true)
        }
    }
}

private struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { onWindow(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if nsView.window != nil {
            onWindow(nsView.window)
        }
    }
}

private struct MergeArrow: View {
    var body: some View {
        MergeArrowShape()
            .stroke(style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
            .foregroundStyle(.tertiary)
    }
}

private struct MergeArrowShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let midY = rect.midY
        let mergeX = rect.minX + rect.width * 0.52
        let tipX = rect.maxX
        let headX = rect.maxX - 5
        let controlX = rect.minX + rect.width * 0.34

        path.move(to: CGPoint(x: rect.minX, y: rect.minY + 8))
        path.addCurve(
            to: CGPoint(x: mergeX, y: midY),
            control1: CGPoint(x: controlX, y: rect.minY + 8),
            control2: CGPoint(x: mergeX - 10, y: midY)
        )
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY - 8))
        path.addCurve(
            to: CGPoint(x: mergeX, y: midY),
            control1: CGPoint(x: controlX, y: rect.maxY - 8),
            control2: CGPoint(x: mergeX - 10, y: midY)
        )
        path.move(to: CGPoint(x: mergeX, y: midY))
        path.addLine(to: CGPoint(x: headX, y: midY))
        path.move(to: CGPoint(x: headX - 3, y: midY - 2.5))
        path.addLine(to: CGPoint(x: tipX, y: midY))
        path.addLine(to: CGPoint(x: headX - 3, y: midY + 2.5))
        return path
    }
}

private struct PlayerCard: View {
    @Bindable var player: FilePlayer
    let isRunning: Bool
    let onRemove: () -> Void

    @State private var isScrubbing = false
    @State private var scrubProgress: Double = 0

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(
                    Color.secondary.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 7) {
                Text(player.fileName ?? "")
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(formatTime(displayedElapsed))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 32, alignment: .leading)
                    if player.isLoading {
                        LoadingSeekBar()
                    } else {
                        SeekBar(progress: displayedProgress) { value, editing in
                            if editing && !isScrubbing {
                                isScrubbing = true
                                player.beginScrub()
                            }
                            scrubProgress = value
                            player.seek(to: value)
                            if !editing {
                                isScrubbing = false
                                player.endScrub()
                                if isRunning {
                                    player.play()
                                }
                            }
                        }
                    }
                    Text(formatTime(displayedRemaining))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 32, alignment: .trailing)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                player.toggleMute()
            } label: {
                Image(systemName: player.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.body)
                    .foregroundStyle(player.muted ? Color.blue : Color.secondary.opacity(0.7))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .help(player.muted ? "Play through speakers" : "Mute speakers")

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Remove")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .rect(cornerRadius: 14, style: .continuous))
        .contextMenu {
            Button(player.muted ? "Play through speakers" : "Mute speakers") {
                player.toggleMute()
            }
            Button("Remove", role: .destructive, action: onRemove)
        }
    }

    private var displayedProgress: Double {
        isScrubbing ? scrubProgress : player.progress
    }

    private var displayedElapsed: TimeInterval {
        displayedProgress * player.duration
    }

    private var displayedRemaining: TimeInterval {
        max(0, player.duration - displayedElapsed)
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let total = max(0, Int(time.rounded(.towardZero)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct LoadingSeekBar: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { timeline in
            let period: TimeInterval = 1.2
            let t = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period

            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Color.secondary.opacity(0.15))
                .frame(height: 4)
                .overlay {
                    GeometryReader { geo in
                        let width = max(geo.size.width * 0.4, 32)
                        LinearGradient(
                            colors: [
                                Color.primary.opacity(0.04),
                                Color.primary.opacity(0.22),
                                Color.primary.opacity(0.04)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: width)
                        .offset(x: -width + CGFloat(t) * (geo.size.width + width))
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
                }
        }
        .frame(maxWidth: .infinity, minHeight: 16)
        .accessibilityLabel("Loading")
    }
}

private struct SeekBar: NSViewRepresentable {
    var progress: Double
    var onScrub: (Double, Bool) -> Void

    func makeNSView(context: Context) -> SeekBarNSView {
        let view = SeekBarNSView()
        view.onScrub = onScrub
        view.progress = progress
        return view
    }

    func updateNSView(_ nsView: SeekBarNSView, context: Context) {
        nsView.onScrub = onScrub
        nsView.progress = progress
        nsView.needsDisplay = true
    }
}

final class SeekBarNSView: NSView {
    var progress: Double = 0
    var onScrub: ((Double, Bool) -> Void)?

    override var isOpaque: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 16)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let trackRect = NSRect(x: 0, y: bounds.midY - 2, width: bounds.width, height: 4)
        NSColor.secondaryLabelColor.withAlphaComponent(0.15).setFill()
        NSBezierPath(roundedRect: trackRect, xRadius: 2, yRadius: 2).fill()

        let clamped = min(max(progress, 0), 1)
        let fillWidth = max(0, bounds.width * clamped)
        if fillWidth > 0 {
            let fillRect = NSRect(x: 0, y: bounds.midY - 2, width: fillWidth, height: 4)
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: fillRect, xRadius: 2, yRadius: 2).fill()
        }
    }

    override func mouseDown(with event: NSEvent) {
        scrub(with: event, editing: true)
        while true {
            guard let next = window?.nextEvent(
                matching: [.leftMouseUp, .leftMouseDragged],
                until: .distantFuture,
                inMode: .eventTracking,
                dequeue: true
            ) else { break }
            if next.type == .leftMouseDragged {
                scrub(with: next, editing: true)
            } else {
                scrub(with: next, editing: false)
                break
            }
        }
    }

    private func scrub(with event: NSEvent, editing: Bool) {
        let location = convert(event.locationInWindow, from: nil)
        let width = max(bounds.width, 1)
        let value = min(max(location.x / width, 0), 1)
        onScrub?(value, editing)
    }
}

private struct SourceRow: View {
    let source: AudioSource
    let onToggle: () -> Void
    let onMute: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onToggle) {
                ZStack {
                    Circle()
                        .strokeBorder(
                            source.enabled ? Color.accentColor : Color.secondary.opacity(0.35),
                            lineWidth: 1.6
                        )
                    if source.enabled {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 8, height: 8)
                    }
                }
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(source.enabled ? "Deactivate source" : "Activate source")

            Image(nsImage: source.icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 28, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .shadow(color: .black.opacity(0.22), radius: 4, y: 1)

            HStack(spacing: 6) {
                Text(source.displayName)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                if !source.isActive {
                    Text("Offline")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 6)

            Button(action: onMute) {
                Image(systemName: source.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.body)
                    .foregroundStyle(source.muted ? Color.blue : Color.secondary.opacity(0.7))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .help(source.muted ? "Play through speakers" : "Mute speakers")

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Remove")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .rect(cornerRadius: 14, style: .continuous))
        .opacity(source.enabled ? 1 : 0.48)
        .contextMenu {
            Button(source.enabled ? "Deactivate" : "Activate", action: onToggle)
            Button(source.muted ? "Play through speakers" : "Mute speakers", action: onMute)
            Button("Remove", role: .destructive, action: onRemove)
        }
    }
}

private struct OutputMeter: View {
    let level: Float

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Color.secondary.opacity(0.12)
                Rectangle()
                    .fill(meterGradient)
                    .frame(width: max(0, geometry.size.width * CGFloat(clampedLevel)))
            }
        }
        .frame(height: 3)
        .accessibilityLabel("Output level")
    }

    private var clampedLevel: Float {
        guard level.isFinite else { return 0 }
        return max(0, min(level, 1))
    }

    private var meterGradient: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: Color.accentColor.opacity(0.4), location: 0),
                .init(color: Color.accentColor.opacity(0.75), location: 0.55),
                .init(color: Color.accentColor, location: 1)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}

struct AppPickerView: View {
    @Bindable var store: SourceStore
    let onClose: () -> Void
    @State private var query = ""
    @State private var running: [RunningAppCandidate] = []
    @State private var installed: [RunningAppCandidate] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button(action: onClose) {
                    Image(systemName: "chevron.left")
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.glass)
                .keyboardShortcut(.cancelAction)
                .help("Back")

                Text("Add Source")
                    .font(.callout.weight(.semibold))

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 8)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Search apps", text: $query)
                    .textFieldStyle(.plain)
                    .font(.callout)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .glassEffect(.regular, in: .rect(cornerRadius: 8, style: .continuous))
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            Group {
                if running.isEmpty && installed.isEmpty {
                    ContentUnavailableView(
                        "No apps",
                        systemImage: "app.dashed",
                        description: Text("Launch an app that plays audio, or install one, then add it here.")
                    )
                } else if filteredRunning.isEmpty && filteredInstalled.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    ScrollView {
                        GlassEffectContainer(spacing: 8) {
                            LazyVStack(alignment: .leading, spacing: 8) {
                                if !filteredRunning.isEmpty {
                                    sectionHeader("Running")
                                    ForEach(filteredRunning) { candidate in
                                        candidateRow(candidate)
                                    }
                                }
                                if !filteredInstalled.isEmpty {
                                    sectionHeader("Installed")
                                        .padding(.top, filteredRunning.isEmpty ? 0 : 8)
                                    ForEach(filteredInstalled) { candidate in
                                        candidateRow(candidate)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.bottom, 12)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            running = store.availableCandidates()
            var excluded = Set(store.sources.map(\.bundleID))
            excluded.formUnion(running.map(\.bundleID))
            installed = ProcessEnumerator.installedApplications(excluding: excluded)
        }
    }

    private var filteredRunning: [RunningAppCandidate] {
        running.filter(matches)
    }

    private var filteredInstalled: [RunningAppCandidate] {
        installed.filter(matches)
    }

    private func matches(_ candidate: RunningAppCandidate) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        return candidate.displayName.localizedCaseInsensitiveContains(trimmed)
            || candidate.bundleID.localizedCaseInsensitiveContains(trimmed)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
    }

    private func candidateRow(_ candidate: RunningAppCandidate) -> some View {
        Button {
            onClose()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                withAnimation(.snappy(duration: 0.3)) {
                    store.add(candidate)
                }
            }
        } label: {
            HStack(spacing: 10) {
                Image(nsImage: candidate.icon)
                    .resizable()
                    .frame(width: 28, height: 28)
                    .cornerRadius(6)
                VStack(alignment: .leading, spacing: 2) {
                    Text(candidate.displayName)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(candidate.bundleID)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if !candidate.processObjectIDs.isEmpty {
                    Text("Audio")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.secondary.opacity(0.12), in: Capsule())
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 12))
    }
}
