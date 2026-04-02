import SwiftUI

struct RootView: View {
    @EnvironmentObject private var vm: AppViewModel
    @EnvironmentObject private var audio: AudioCaptureEngine
    @FocusState private var focusedField: SidebarFocus?

    private enum SidebarFocus {
        case search
    }

    var body: some View {
        Group {
            if vm.workspaceFolderURL == nil {
                workspacePickerGate
            } else {
                VStack(spacing: 0) {
                    topBar
                    Divider().opacity(0.35)
                    HSplitView {
                        chordSidebar
                            .frame(minWidth: 260, idealWidth: 280, maxWidth: 360)
                        mainPane
                            .frame(minWidth: 560)
                    }
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .focusable()
        .onKeyPress(.space) {
            guard vm.workspaceFolderURL != nil else { return .ignored }
            guard !vm.isFinalizingAudio else { return .ignored }
            if focusedField == .search { return .ignored }
            vm.toggleRecord()
            return .handled
        }
        .onAppear {
            vm.refreshDevices()
            vm.startAudioSessionIfNeeded()
        }
    }

    private var workspacePickerGate: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Choose a workspace folder")
                .font(.title2.weight(.semibold))
            Text("Recordings are saved as WAV files in this folder. Existing files named like ChordName_take01.wav are loaded when they match the chord library.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button("Choose Folder…") {
                vm.chooseWorkspaceFolder()
            }
            .keyboardShortcut(.defaultAction)
            .controlSize(.large)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }

    private var topBar: some View {
        HStack(alignment: .center, spacing: 16) {
            Text("ChordSaver")
                .font(.headline)
                .foregroundStyle(.secondary)

            Picker("Input", selection: Binding(
                get: { vm.selectedDevice.deviceID },
                set: { id in
                    if let d = vm.devices.first(where: { $0.deviceID == id }) {
                        vm.selectDevice(d)
                    }
                }
            )) {
                ForEach(vm.devices) { d in
                    Text(d.name).tag(d.deviceID)
                }
            }
            .frame(minWidth: 220)

            Button("Refresh devices") {
                vm.refreshDevices()
            }

            Spacer()

            if let url = vm.workspaceFolderURL {
                HStack(spacing: 8) {
                    Text("Workspace")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(url.lastPathComponent)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 200, alignment: .trailing)
                    Button("Change…") {
                        vm.chooseWorkspaceFolder()
                    }
                    .font(.caption)
                }
            }

            formatBadge
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    private var formatBadge: some View {
        HStack(spacing: 8) {
            Text("Capture")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("48 kHz · 24-bit PCM · stereo WAV")
                .font(.caption.monospaced())
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
        }
    }

    private var chordSidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Chord list")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 10)

            TextField("Search…", text: $vm.search)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 12)
                .focused($focusedField, equals: .search)

            List(selection: Binding(
                get: { vm.currentChord?.id },
                set: { id in
                    if let id { vm.jumpToChord(id: id) }
                }
            )) {
                ForEach(vm.filteredChords) { chord in
                    HStack(alignment: .center, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(chord.displayName)
                                .font(.body.weight(.medium))
                            Text(chord.category)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer(minLength: 4)
                        if vm.chordIdsWithRecordedTakes.contains(chord.id) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.body)
                                .foregroundStyle(.green)
                                .accessibilityLabel("Recorded")
                        }
                    }
                    .tag(chord.id)
                }
            }
            .listStyle(.sidebar)
        }
    }

    private var mainPane: some View {
        VStack(spacing: 16) {
            RecorderStrip(audio: audio, vm: vm, canRecord: vm.workspaceFolderURL != nil)

            if let chord = vm.currentChord {
                Text(chord.displayName)
                    .font(.system(size: 44, weight: .semibold, design: .rounded))
                Text("Chord \(vm.currentIndex + 1) of \(vm.chords.count)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                FretboardDiagramView(chord: chord)
                    .frame(height: 280)
                    .padding(.horizontal)
            } else {
                ContentUnavailableView("No chords", systemImage: "guitars")
            }

            LastTakePanel(
                takes: vm.takesForCurrentChord,
                lastTake: vm.mostRecentTakeForCurrentChord,
                emptyMessage: vm.currentChord == nil
                    ? "Select a chord in the list."
                    : "No takes for this chord yet — Space to record."
            )

            Text(vm.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)

            debugLogSection

            Spacer(minLength: 0)
        }
        .padding(.vertical, 16)
    }

    private var debugLogSection: some View {
        DisclosureGroup(isExpanded: $vm.debugLogExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                ScrollView {
                    Text(vm.debugLogLines.joined(separator: "\n"))
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 100, maxHeight: 220)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))

                HStack(spacing: 12) {
                    Button("Copy log") {
                        vm.copyDebugLogToPasteboard()
                    }
                    Button("Clear") {
                        vm.clearDebugLog()
                    }
                }
                .font(.caption)
            }
            .padding(.horizontal)
        } label: {
            HStack(spacing: 8) {
                Text("Debug log")
                    .font(.subheadline.weight(.semibold))
                Text("(\(vm.debugLogLines.count) lines)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
    }
}
