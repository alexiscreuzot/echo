import SwiftUI

struct SourceListView: View {
    @Bindable var store: SourceStore
    @Bindable var router: AudioRouter
    @State private var showingPicker = false

    var body: some View {
        VStack(spacing: 0) {
            sourceList
                .frame(maxHeight: .infinity)
            actionBar
        }
        .padding(.top, 36)
        .frame(minWidth: 300, minHeight: EchoWindowLayout.minHeight)
        .onAppear {
            store.refreshProcessObjects()
        }
        .task {
            await router.prepareDevice()
        }
        .onChange(of: store.sources) { _, newSources in
            router.sync(sources: newSources)
        }
        .sheet(isPresented: $showingPicker) {
            AppPickerView(store: store)
        }
    }

    private var sourceList: some View {
        Group {
            if store.sources.isEmpty {
                emptyHero
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        howItWorks
                        GlassEffectContainer(spacing: 8) {
                            LazyVStack(spacing: 8) {
                                ForEach(store.sources) { source in
                                    SourceRow(
                                        source: source,
                                        level: router.levels[source.bundleID] ?? 0,
                                        isMetering: router.isRunning && source.enabled
                                    ) {
                                        store.toggle(source)
                                    } onMute: {
                                        store.toggleMute(source)
                                    } onRemove: {
                                        store.remove(id: source.bundleID)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                }
            }
        }
    }

    private var emptyHero: some View {
        howItWorks
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 16)
    }

    private var howItWorks: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                flowNode("App audio", systemImage: "speaker.wave.2.fill")
                Image(systemName: "arrow.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.tertiary)
                flowNode("Virtual device", systemImage: "waveform")
            }

            Text("Echo appears as a microphone you can select.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .shadow(color: .black.opacity(0.28), radius: 8, y: 1)
    }

    private func flowNode(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.callout.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .glassEffect(.regular, in: .rect(cornerRadius: 12, style: .continuous))
    }

    private var actionBar: some View {
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

            Spacer(minLength: 8)

            Button {
                showingPicker = true
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.glass)
            .help("Add an app")

            Button {
                if router.isRunning {
                    router.stop()
                } else {
                    store.refreshProcessObjects()
                    router.start(sources: store.sources)
                }
            } label: {
                Label(
                    router.isRunning ? "Stop" : "Start",
                    systemImage: router.isRunning ? "stop.fill" : "play.fill"
                )
                .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.glassProminent)
            .keyboardShortcut(.space, modifiers: [])
            .disabled(!router.isRunning && !store.sources.contains(where: { $0.enabled }))
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }
}

private struct SourceRow: View {
    let source: AudioSource
    let level: Float
    let isMetering: Bool
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
                .frame(width: 36, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .shadow(color: .black.opacity(0.22), radius: 4, y: 1)

            VStack(alignment: .leading, spacing: 7) {
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
                LevelMeter(level: isMetering ? level : 0)
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
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .glassEffect(.regular, in: .rect(cornerRadius: 18, style: .continuous))
        .opacity(source.enabled ? 1 : 0.48)
        .contextMenu {
            Button(source.enabled ? "Deactivate" : "Activate", action: onToggle)
            Button(source.muted ? "Play through speakers" : "Mute speakers", action: onMute)
            Button("Remove", role: .destructive, action: onRemove)
        }
    }
}

private struct LevelMeter: View {
    let level: Float

    var body: some View {
        Capsule()
            .fill(Color.secondary.opacity(0.15))
            .frame(height: 4)
            .overlay(alignment: .leading) {
                GeometryReader { geometry in
                    Capsule()
                        .fill(meterGradient)
                        .frame(width: max(0, geometry.size.width * CGFloat(clampedLevel)))
                }
            }
            .clipShape(Capsule())
    }

    private var clampedLevel: Float {
        guard level.isFinite else { return 0 }
        return max(0, min(level, 1))
    }

    private var meterGradient: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: .green, location: 0),
                .init(color: .green, location: 0.55),
                .init(color: .orange, location: 0.72),
                .init(color: .red, location: 1)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}

struct AppPickerView: View {
    @Bindable var store: SourceStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var running: [RunningAppCandidate] = []
    @State private var installed: [RunningAppCandidate] = []

    var body: some View {
        NavigationStack {
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
                        .padding(16)
                    }
                }
            }
            .navigationTitle("Add Source")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .buttonStyle(.glass)
                        .keyboardShortcut(.cancelAction)
                }
            }
            .searchable(text: $query, placement: .automatic, prompt: "Search apps")
        }
        .frame(width: 360, height: 440)
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
            store.add(candidate)
            dismiss()
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
                if candidate.processObjectID != nil {
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
