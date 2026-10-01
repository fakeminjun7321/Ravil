import Foundation

struct TranscriptionOptions {
    let language: String
    let translateToEnglish: Bool
    let keywordPrompt: String
    var useVAD: Bool = false

    static let standard = TranscriptionOptions(language: "auto", translateToEnglish: false, keywordPrompt: "")
}

struct WhisperTranscriber {
    let executable: URL
    let model: URL
    var outputDirectory: URL = AppPaths.transcriptionOutput

    var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: executable.path)
        && FileManager.default.fileExists(atPath: model.path)
        && (AppPaths.bundledWhisperCLI?.standardizedFileURL != executable.standardizedFileURL
            || AppPaths.bundledGGMLBackends != nil)
    }

    func transcribe(audio: URL, options: TranscriptionOptions = .standard) throws -> [RecognizedPhrase] {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw TranscriptionError.missingExecutable(executable.path)
        }
        guard FileManager.default.fileExists(atPath: model.path) else {
            throw TranscriptionError.missingModel(model.path)
        }
        guard ["auto", "ko", "en", "ja", "zh"].contains(options.language) else {
            throw TranscriptionError.unsupportedLanguage(options.language)
        }
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: outputDirectory.path)
        let outputBase = outputDirectory.appendingPathComponent(
            "\(audio.deletingPathExtension().lastPathComponent)-\(UUID().uuidString)")
        let process = Process()
        process.executableURL = executable
        var arguments = ["-m", model.path, "-f", audio.path, "-l", options.language,
                         "-oj", "-of", outputBase.path, "-np"]
        if options.translateToEnglish { arguments.append("--translate") }
        if options.useVAD {
            guard let vad = AppPaths.bundledVADModel else { throw TranscriptionError.missingVAD }
            arguments += ["--vad", "--vad-model", vad.path]
        }
        let prompt = options.keywordPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !prompt.isEmpty { arguments += ["--prompt", prompt] }
        process.arguments = arguments
        if AppPaths.bundledWhisperCLI?.standardizedFileURL == executable.standardizedFileURL,
           let backends = AppPaths.bundledGGMLBackends {
            // ggml searches the executable directory and current directory after its
            // build-time path. GGML_BACKEND_PATH expects one plugin file, not a directory.
            process.currentDirectoryURL = backends
        }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw TranscriptionError.processFailed(process.terminationStatus) }
        let json = outputBase.appendingPathExtension("json")
        let data = try Data(contentsOf: json)
        return try JSONDecoder().decode(WhisperOutput.self, from: data).transcription
    }
}

enum TranscriptionError: LocalizedError {
    case missingExecutable(String), missingModel(String), missingVAD, unsupportedLanguage(String), processFailed(Int32)
    var errorDescription: String? {
        switch self {
        case .missingExecutable(let path): return "Whisper 실행 파일을 찾지 못했습니다: \(path)"
        case .missingModel(let path): return "로컬 Whisper 모델을 찾지 못했습니다: \(path)"
        case .missingVAD: return "번들된 음성 구간 감지 모델을 찾지 못했습니다."
        case .unsupportedLanguage(let language): return "지원하지 않는 전사 언어입니다: \(language)"
        case .processFailed(let code): return "로컬 전사가 종료 코드 \(code)로 실패했습니다. 녹음 파일은 보존됐습니다."
        }
    }
}
