// AudioPlayer: a small music player for trying sound under SimRun.
//   simrun run build/apps/AudioPlayer.app [file or folder…]
// Add files with the Mac's open panel (Add Files…) or on the command line; anything AVAudioPlayer reads plays (MP3, AAC/M4A,
// ALAC, WAV, AIFF, CAF, FLAC…). Tap a track to play it; the player goes on to the next one when it ends.
import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

@main struct AudioPlayerApp: App {
    @StateObject private var player = Player()
    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(player)
                .onAppear { player.add(CommandLine.arguments.dropFirst().map { URL(fileURLWithPath: $0) }) }
        }
    }
}

struct Track: Identifiable {
    let id = UUID()
    let url: URL
    var title: String
    var artist: String?
    var duration: TimeInterval?
}

@MainActor final class Player: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var tracks: [Track] = []
    @Published var current: Track.ID?
    @Published var isPlaying = false
    @Published var time: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var volume: Float = 1 {
        didSet {
            audio?.volume = volume
        }
    }
    @Published var error: String?
    private var audio: AVAudioPlayer?
    private var timer: Timer?

    override init() {
        super.init()
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            self.error = "Audio session: \(error.localizedDescription)"
        }
    }

    // Files are added as they are; folders with the audio files in them (not their subfolders).
    func add(_ urls: [URL]) {
        var files: [URL] = []
        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
                error = "No such file: \(url.path)"
                continue
            }
            if isDir.boolValue {
                let items = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
                files += items.filter(isAudioFile)
                    .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            } else {
                files.append(url)
            }
        }
        for url in files {
            let track = Track(url: url, title: url.deletingPathExtension().lastPathComponent)
            tracks.append(track)
            Task { await loadMetadata(of: track.id, url: url) }
        }
    }

    private func loadMetadata(of id: Track.ID, url: URL) async {
        let asset = AVURLAsset(url: url)
        let metadata = (try? await asset.load(.commonMetadata)) ?? []
        let title = try? await AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierTitle).first?.load(.stringValue)
        let artist = try? await AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierArtist).first?.load(.stringValue)
        let duration = try? await asset.load(.duration)
        guard let i = tracks.firstIndex(where: { $0.id == id }) else {
            return
        }
        if let title, !title.isEmpty {
            tracks[i].title = title
        }
        tracks[i].artist = artist ?? nil
        if let duration, duration.isNumeric {
            tracks[i].duration = duration.seconds
        }
    }

    var currentTrack: Track? { tracks.first { $0.id == current } }

    func play(_ id: Track.ID) {
        guard let track = tracks.first(where: { $0.id == id }) else {
            return
        }
        stop()
        do {
            let audio = try AVAudioPlayer(contentsOf: track.url)
            audio.delegate = self
            audio.volume = volume
            guard audio.play() else {
                throw CocoaError(.fileReadCorruptFile)
            }
            self.audio = audio
            current = id
            duration = audio.duration
            time = 0
            isPlaying = true
            error = nil
            timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    if let self, let a = self.audio {
                        self.time = a.currentTime
                    }
                }
            }
        } catch {
            current = id
            self.error = "Can't play \(track.url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    func togglePlay() {
        guard let audio else {
            if let first = current ?? tracks.first?.id {
                play(first)
            }
            return
        }
        if audio.isPlaying {
            audio.pause()
        } else {
            audio.play()
        }
        isPlaying = audio.isPlaying
    }

    func seek(to t: TimeInterval) {
        audio?.currentTime = t
        time = t
    }

    func skip(_ by: Int) {
        guard let i = tracks.firstIndex(where: { $0.id == current }) else {
            return
        }
        if by < 0, time > 3 {   // back: to the start first, like Music
            seek(to: 0)
            return
        }
        let j = i + by
        if tracks.indices.contains(j) {
            play(tracks[j].id)
        }
    }

    func remove(at offsets: IndexSet) {
        if let current, offsets.contains(where: { tracks[$0].id == current }) {
            stop()
            self.current = nil
        }
        tracks.remove(atOffsets: offsets)
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        audio?.stop()
        audio = nil
        isPlaying = false
        time = 0
        duration = 0
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        MainActor.assumeIsolated {
            guard let i = tracks.firstIndex(where: { $0.id == current }) else {
                return
            }
            if i + 1 < tracks.count {
                play(tracks[i + 1].id)
            } else {
                stop()
                time = 0
            }
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        MainActor.assumeIsolated {
            self.error = "Decoding failed: \(error?.localizedDescription ?? "unknown error")"
            stop()
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var player: Player
    @State private var importing = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if player.tracks.isEmpty {
                    ContentUnavailableView {
                        Label("No Music", systemImage: "music.note.list")
                    } description: {
                        Text("Add audio files from your Mac, or pass them to simrun run.")
                    } actions: {
                        Button("Add Files…") { importing = true }.buttonStyle(.borderedProminent)
                    }
                } else {
                    List {
                        ForEach(player.tracks) { track in
                            Button { player.play(track.id) } label: { TrackRow(track: track, isCurrent: track.id == player.current, isPlaying: player.isPlaying) }
                                .foregroundStyle(.primary)
                        }
                        .onDelete { player.remove(at: $0) }
                    }
                    .listStyle(.plain)
                }
                NowPlaying()
            }
            .navigationTitle("Audio Player")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { importing = true } label: { Label("Add Files", systemImage: "plus") }
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.audio, .folder], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls):
                    for url in urls {   // kept for as long as the app runs
                        _ = url.startAccessingSecurityScopedResource()
                    }
                    player.add(urls)
                case .failure(let error):
                    player.error = error.localizedDescription
                }
            }
        }
    }
}

struct TrackRow: View {
    let track: Track
    let isCurrent: Bool
    let isPlaying: Bool
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isCurrent ? (isPlaying ? "speaker.wave.2.fill" : "pause.fill") : "music.note")
                .foregroundStyle(isCurrent ? Color.accentColor : .secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title).fontWeight(isCurrent ? .semibold : .regular).lineLimit(1)
                Text(track.artist ?? track.url.pathExtension.uppercased()).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if let d = track.duration {
                Text(format(d)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }
}

struct NowPlaying: View {
    @EnvironmentObject var player: Player
    @State private var scrubbing: TimeInterval?

    var body: some View {
        VStack(spacing: 12) {
            if let error = player.error {
                Label(error, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            VStack(spacing: 2) {
                Text(player.currentTrack?.title ?? "Not Playing").font(.headline).lineLimit(1)
                Text(player.currentTrack?.artist ?? " ").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            VStack(spacing: 4) {
                Slider(value: Binding(get: { scrubbing ?? player.time }, set: { scrubbing = $0 }),
                       in: 0...max(player.duration, 0.01)) { editing in
                    if !editing, let t = scrubbing {
                        player.seek(to: t)
                        scrubbing = nil
                    }
                }
                .disabled(player.duration == 0)
                HStack {
                    Text(format(scrubbing ?? player.time))
                    Spacer()
                    Text("-" + format(max(player.duration - (scrubbing ?? player.time), 0)))
                }
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            HStack(spacing: 44) {
                Button { player.skip(-1) } label: { Image(systemName: "backward.fill") }
                Button { player.togglePlay() } label: { Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 36)) }
                    .frame(width: 44)
                Button { player.skip(1) } label: { Image(systemName: "forward.fill") }
            }
            .font(.title2)
            .disabled(player.tracks.isEmpty)
            HStack {
                Image(systemName: "speaker.fill")
                Slider(value: $player.volume, in: 0...1)
                Image(systemName: "speaker.wave.3.fill")
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding()
        .background(.bar)
    }
}

// By extension first: without LaunchServices (SimRun), UTType knows only the core types, not m4a, aiff or flac.
private let audioExtensions: Set<String> = ["mp3", "m4a", "m4b", "aac", "adts", "wav", "wave", "aif", "aiff", "aifc", "caf", "flac", "mp4", "3gp", "amr", "au", "snd"]
private func isAudioFile(_ url: URL) -> Bool {
    audioExtensions.contains(url.pathExtension.lowercased()) || (UTType(filenameExtension: url.pathExtension)?.conforms(to: .audio) ?? false)
}

private func format(_ t: TimeInterval) -> String {
    let s = Int(t.rounded(.down))
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
}
