import Foundation

enum AppPaths {
    static var applicationSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Ravil", isDirectory: true)
    }

    static var database: URL { applicationSupport.appendingPathComponent("ravil.sqlite") }
    static var recordings: URL { applicationSupport.appendingPathComponent("Recordings", isDirectory: true) }
    static var transcriptionOutput: URL { applicationSupport.appendingPathComponent("Transcripts", isDirectory: true) }
    static var legacyDatabase: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Ravil/data/lecture-os.db")
    }
    static var altDatabase: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/alt/data/database/lecture_notes.db")
    }
    private static var legacyAltModel: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/alt/models/whisper-cpp/ggml-large-v3-turbo-q5_0.bin")
    }
    static var localModel: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/Ravil/Models/ggml-large-v3-turbo-q5_0.bin")
    }

    static var bundledModel: URL? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let model = resources.appendingPathComponent("Models/ggml-large-v3-turbo-q5_0.bin")
        return FileManager.default.fileExists(atPath: model.path) ? model : nil
    }

    static var preferredModel: URL { bundledModel ?? localModel }

    static var bundledWhisperCLI: URL? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let executable = resources.appendingPathComponent("Whisper/bin/whisper-cli")
        return FileManager.default.isExecutableFile(atPath: executable.path) ? executable : nil
    }

    static var bundledGGMLBackends: URL? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let sourceBuilt = resources.appendingPathComponent("Whisper/bin", isDirectory: true)
        if FileManager.default.isReadableFile(atPath: sourceBuilt.appendingPathComponent("libggml-metal.so").path),
           FileManager.default.isReadableFile(atPath: sourceBuilt.appendingPathComponent("libggml-cpu.so").path) {
            return sourceBuilt
        }
        let directory = resources.appendingPathComponent("Whisper/backends", isDirectory: true)
        let metal = directory.appendingPathComponent("libggml-metal.so")
        let cpu = directory.appendingPathComponent("libggml-cpu-apple_m4.so")
        return FileManager.default.isReadableFile(atPath: metal.path)
            && FileManager.default.isReadableFile(atPath: cpu.path) ? directory : nil
    }

    static var bundledVADModel: URL? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let model = resources.appendingPathComponent("Whisper/bin/ggml-silero-v6.2.0.bin")
        return FileManager.default.isReadableFile(atPath: model.path) ? model : nil
    }

    static var whisperCLI: URL {
        if let bundledWhisperCLI { return bundledWhisperCLI }
        let candidates = ["/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli"]
        return URL(fileURLWithPath: candidates.first(where: FileManager.default.isExecutableFile(atPath:)) ?? candidates[0])
    }

    static func resolvedModelPath(saved: String?) -> String {
        guard let saved, !saved.isEmpty, saved != legacyAltModel.path else { return preferredModel.path }
        return saved
    }

    static func resolvedWhisperCLIPath(saved: String?) -> String {
        guard let saved, !saved.isEmpty,
              !["/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli"].contains(saved) else {
            return whisperCLI.path
        }
        return saved
    }
}
