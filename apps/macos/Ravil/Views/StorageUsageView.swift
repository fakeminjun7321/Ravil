import Foundation
import SwiftUI

private struct StorageUsage: Sendable {
    let modelBytes: Int64
    let materialBytes: Int64
    let materialFiles: Int
    let databaseBytes: Int64

    static func measure() -> StorageUsage {
        let manager = FileManager.default
        func size(of file: URL?) -> Int64 {
            guard let file,
                  let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else { return 0 }
            return Int64(values.fileSize ?? 0)
        }

        let materials = AppPaths.applicationSupport.appendingPathComponent("Materials", isDirectory: true)
        let contents = manager.enumerator(at: materials,
                                          includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                                          options: [.skipsHiddenFiles, .skipsPackageDescendants])
        var materialBytes: Int64 = 0
        var materialFiles = 0
        while let file = contents?.nextObject() as? URL {
            guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else { continue }
            materialBytes += Int64(values.fileSize ?? 0)
            materialFiles += 1
        }
        return StorageUsage(modelBytes: size(of: AppPaths.bundledModel),
                            materialBytes: materialBytes, materialFiles: materialFiles,
                            databaseBytes: size(of: AppPaths.database))
    }
}

struct StorageUsageView: View {
    @State private var usage: StorageUsage?
    @State private var isMeasuring = false

    var body: some View {
        Group {
            if let usage {
                LabeledContent("앱에 포함된 Whisper 모델", value: format(usage.modelBytes))
                LabeledContent("보관한 PDF \(usage.materialFiles)개", value: format(usage.materialBytes))
                LabeledContent("Ravil 데이터베이스", value: format(usage.databaseBytes))
            } else {
                ProgressView("저장 공간 계산 중")
            }
            Button("사용량 다시 계산") { measure() }
                .disabled(isMeasuring)
            Text("원본 Alt·Google Drive 파일은 여기서 지우지 않습니다. 과거 PDF 판본도 자동 삭제하지 않습니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task { measure() }
    }

    private func measure() {
        guard !isMeasuring else { return }
        isMeasuring = true
        Task {
            usage = await Task.detached(priority: .utility) { StorageUsage.measure() }.value
            isMeasuring = false
        }
    }

    private func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
