import AppKit
import CallWhisperKit

/// Aktualizacja z GitHuba: `git pull --ff-only` w klonie, z którego apka była
/// zbudowana, potem `bundle.sh` i restart.
///
/// Tylko w jedną stronę: żadnego commita ani pusha. Gdy w klonie są lokalne
/// zmiany albo commity, których nie ma na GitHubie, nic nie ruszamy — pull
/// z merge'em albo rebase w cudzym roboczym repo to proszenie się o kłopoty.
@MainActor
final class Updater: ObservableObject {
    enum State: Equatable {
        case idle
        case checking
        /// Są zmiany, ale trwa nasłuch albo import — czekamy na koniec.
        case waiting(behind: Int)
        case building
        /// Nie da się bezpiecznie zaktualizować; powód dla człowieka.
        case blocked(String)
        case failed(String)
    }

    @Published private(set) var state = State.idle
    @Published private(set) var lastCheck: Date?

    private let recorder: Recorder
    private let settings = AppSettings.shared
    private var timer: Timer?
    private static let interval: TimeInterval = 30 * 60
    /// Co ile sprawdzamy, czy nasłuch już się skończył.
    private static let idlePoll: TimeInterval = 60

    /// Ścieżkę klona zapisuje `bundle.sh` w Info.plist. Bez niej (np. `swift run`)
    /// aktualizacja jest wyłączona.
    let repo: URL? = (Bundle.main.object(forInfoDictionaryKey: "CWSourceRepo") as? String)
        .map { URL(fileURLWithPath: $0) }
        .flatMap { FileManager.default.fileExists(atPath: $0.appendingPathComponent(".git").path) ? $0 : nil }

    nonisolated static var logURL: URL {
        WhisperServer.logDirectory.appendingPathComponent("update.log")
    }

    init(recorder: Recorder) {
        self.recorder = recorder
    }

    func start() {
        guard repo != nil else { return }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.idlePoll, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        Task { await check() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard settings.autoUpdate else { return }
        if case .waiting = state {
            Task { await check() }
        } else if Date().timeIntervalSince(lastCheck ?? .distantPast) >= Self.interval {
            Task { await check() }
        }
    }

    /// `force` = kliknięte „Sprawdź teraz": działa też przy wyłączonej automatyce.
    func check(force: Bool = false) async {
        guard let repo, force || settings.autoUpdate else { return }
        switch state { case .checking, .building: return; default: break }
        state = .checking
        lastCheck = Date()

        guard await git(repo, "fetch", "--quiet").ok else {
            state = .failed("Nie udało się połączyć z GitHubem")
            return
        }
        guard await git(repo, "rev-parse", "--abbrev-ref", "@{u}").ok else {
            state = .blocked("Gałąź bez upstreamu na GitHubie")
            return
        }
        let behind = Int(await git(repo, "rev-list", "--count", "HEAD..@{u}").out) ?? 0
        let ahead = Int(await git(repo, "rev-list", "--count", "@{u}..HEAD").out) ?? 0
        guard behind > 0 else { state = .idle; return }
        guard ahead == 0 else {
            state = .blocked("Lokalne commity niewypchnięte na GitHuba — pomijam")
            return
        }
        guard await git(repo, "status", "--porcelain", "--untracked-files=no").out.isEmpty else {
            state = .blocked("Niezacommitowane zmiany w \(repo.lastPathComponent) — pomijam")
            return
        }
        guard !recorder.isRunning, !recorder.isProcessing else {
            state = .waiting(behind: behind)
            return
        }

        state = .building
        guard await git(repo, "pull", "--ff-only", "--quiet").ok else {
            state = .failed("git pull --ff-only się nie udał")
            return
        }
        let build = await run("/bin/bash", [repo.appendingPathComponent("macos/tools/bundle.sh").path, "release"],
                              in: repo, log: true)
        guard build.ok else {
            state = .failed("Przebudowa nie wyszła, szczegóły w \(Self.logURL.path)")
            return
        }
        relaunch()
    }

    /// Nowa paczka leży w tym samym miejscu co stara. Pomocniczy proces czeka,
    /// aż ten się zamknie, i otwiera ją od nowa.
    private func relaunch() {
        // Paczka zmieniła nazwę (call-whisper.app -> brqs-whisper.app): po
        // przebudowie otwieramy tę, którą zbudował bundle.sh, a nie starą ścieżkę.
        let built = repo?.appendingPathComponent("macos/build/brqs-whisper.app").path
        let app = built.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil } ?? Bundle.main.bundleURL.path
        let pid = ProcessInfo.processInfo.processIdentifier
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"\(app)\""]
        try? helper.run()
        NSApp.terminate(nil)
    }

    private struct Output { var ok: Bool; var out: String }

    private func git(_ repo: URL, _ args: String...) async -> Output {
        await run("/usr/bin/git", ["-C", repo.path] + args, in: repo, log: false)
    }

    /// Procesy z GUI dostają okrojony PATH, a `bundle.sh` woła `swift`, `git`
    /// i `codesign` — stąd jawny PATH.
    private func run(_ tool: String, _ args: [String], in dir: URL, log: Bool) async -> Output {
        await Task.detached {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: tool)
            task.arguments = args
            task.currentDirectoryURL = dir
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
            env["GIT_TERMINAL_PROMPT"] = "0"
            task.environment = env
            let pipe = Pipe()
            if log {
                try? FileManager.default.createDirectory(at: WhisperServer.logDirectory, withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: Updater.logURL.path, contents: nil)
                let handle = try? FileHandle(forWritingTo: Updater.logURL)
                task.standardOutput = handle
                task.standardError = handle
            } else {
                task.standardOutput = pipe
                task.standardError = FileHandle.nullDevice
            }
            guard (try? task.run()) != nil else { return Output(ok: false, out: "") }
            let data = log ? Data() : pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            return Output(ok: task.terminationStatus == 0,
                          out: String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }.value
    }
}
