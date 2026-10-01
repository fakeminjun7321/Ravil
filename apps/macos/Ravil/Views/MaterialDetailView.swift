import AppKit
import SwiftUI

struct MaterialDetailView: View {
    let model: AppModel
    let material: MaterialItem
    @State private var versions: [GoodnotesVersionItem] = []
    @State private var summary: GoodnotesChangeSummary?
    @State private var ocrStatus: MaterialOCRStatus?
    @State private var visualDiff: GoodnotesVisualDiffResult?
    @State private var isComparing = false
    @State private var showOCRReview = false
    @State private var showClassificationEditor = false
    @State private var ocrTask: Task<Void, Never>?
    @State private var isOCRRunning = false
    @State private var ocrError: String?
    @State private var selectedVersionID: String?
    @State private var showChanges = false

    private var selectedVersion: GoodnotesVersionItem? {
        versions.first { $0.materialID == selectedVersionID }
    }

    private var shownPath: String? { selectedVersion?.localPath ?? material.localPath }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if !versions.isEmpty {
                    versionPicker
                }
                if let ocrStatus, ocrStatus.candidatePages > 0 {
                    ocrControls(ocrStatus)
                }
                Divider()
                if let shownPath, FileManager.default.fileExists(atPath: shownPath) {
                    PDFMaterialPreview(url: URL(fileURLWithPath: shownPath),
                                       initialPage: model.requestedMaterialIDFromSearch == material.id
                                           ? (model.requestedMaterialPageFromSearch ?? 1) : 1)
                        .id(model.materialPageJumpID)
                        .frame(maxWidth: .infinity, minHeight: 480)
                }
            }
            .padding(24)
            .frame(maxWidth: 1000, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .task(id: material.id) {
            let history = model.goodnotesHistory(for: material.id)
            versions = history.0
            summary = history.1
            selectedVersionID = history.0.first?.materialID
            ocrStatus = model.goodnotesOCRStatus(for: material.id)
            guard history.0.count >= 2 else { return }
            isComparing = true
            let currentPath = history.0[0].localPath
            let previousPath = history.0[1].localPath
            let worker = Task.detached(priority: .utility) {
                try? GoodnotesVisualDiff.compare(previousPath: previousPath, currentPath: currentPath)
            }
            let result = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled else { return }
            visualDiff = result
            isComparing = false
        }
        .sheet(isPresented: $showOCRReview, onDismiss: {
            ocrStatus = model.goodnotesOCRStatus(for: material.id)
        }) {
            OCRReviewView(model: model, material: material)
        }
        .sheet(isPresented: $showClassificationEditor) {
            GoodnotesClassificationEditor(model: model, material: material)
        }
        .onDisappear {
            ocrTask?.cancel()
            if model.requestedMaterialIDFromSearch == material.id {
                model.requestedMaterialIDFromSearch = nil
                model.requestedMaterialPageFromSearch = nil
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 16) {
                Text(material.title)
                    .font(.system(size: 22, weight: .semibold))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("원본 열기", systemImage: "arrow.up.right.square") {
                    if let shownPath, FileManager.default.fileExists(atPath: shownPath) {
                        NSWorkspace.shared.open(URL(fileURLWithPath: shownPath))
                    } else {
                        model.openMaterial(material)
                    }
                }
                .controlSize(.small)
                .fixedSize()
                .help(versions.isEmpty ? "원본 열기" : "표시 중인 판본 열기")
            }
            Text([material.course.isEmpty ? "미분류" : material.course,
                  material.teacherName, material.documentKind].compactMap { $0 }.joined(separator: " · "))
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Text(material.status == "ingested" ? "인덱싱 완료" : "Drive 자료")
                if let pages = selectedVersion?.pageCount ?? material.pageCount {
                    Text("\(pages)쪽")
                        .monospacedDigit()
                }
                Spacer(minLength: 8)
                if !versions.isEmpty {
                    Button(material.classificationNeedsReview ? "분류 확인" : "분류 수정") {
                        showClassificationEditor = true
                    }
                    .controlSize(.small)
                } else if material.classificationNeedsReview {
                    Label("분류 확인 필요", systemImage: "exclamationmark.circle")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func ocrControls(_ status: MaterialOCRStatus) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    ocrSummary(status)
                        .fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 8)
                    ocrActions(status)
                }
                VStack(alignment: .leading, spacing: 8) {
                    ocrSummary(status)
                    ocrActions(status)
                }
            }
            if let ocrError {
                Text(ocrError)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func ocrSummary(_ status: MaterialOCRStatus) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("텍스트 인식 \(status.processedPages)/\(status.candidatePages)쪽")
                .font(.callout)
                .monospacedDigit()
            HStack(spacing: 8) {
                Text("검토 완료 \(status.approvedPages)쪽")
                if status.processedPages > status.approvedPages {
                    Text("미검토 \(status.processedPages - status.approvedPages)쪽")
                }
                if status.lowConfidencePages > 0 {
                    Text("낮은 신뢰도 \(status.lowConfidencePages)쪽")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .help("기기 내 OCR 결과입니다. 원본 PDF와 대조해 검토할 수 있습니다.")
    }

    private func ocrActions(_ status: MaterialOCRStatus) -> some View {
        HStack(spacing: 8) {
            if isOCRRunning {
                ProgressView().controlSize(.small)
                Button("중단") { ocrTask?.cancel() }
            } else if status.processedPages < status.candidatePages {
                Button("인식 시작") { startOCR() }
            }
            Button("원문 검토") { showOCRReview = true }
                .disabled(status.processedPages == 0)
        }
        .controlSize(.small)
        .fixedSize()
    }

    private func startOCR() {
        guard !isOCRRunning else { return }
        let materialID = material.id
        isOCRRunning = true
        ocrError = nil
        ocrTask = Task {
            defer { isOCRRunning = false; ocrTask = nil }
            do {
                while !Task.isCancelled {
                    let worker = Task.detached(priority: .utility) {
                        let database = try LibraryDatabase()
                        return try database.runGoodnotesOCR(limit: 5, materialID: materialID)
                    }
                    let report = try await withTaskCancellationHandler {
                        try await worker.value
                    } onCancel: {
                        worker.cancel()
                    }
                    try Task.checkCancellation()
                    ocrStatus = model.goodnotesOCRStatus(for: materialID)
                    model.updateSearch()
                    if report.failed > 0 {
                        ocrError = "일부 페이지의 OCR에 실패했습니다. 기록을 확인한 뒤 다시 시도해 주세요."
                        break
                    }
                    if report.attempted == 0 { break }
                }
            } catch is CancellationError {
                ocrStatus = model.goodnotesOCRStatus(for: materialID)
            } catch {
                ocrError = error.localizedDescription
            }
        }
    }

    private var versionPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text("판본")
                    .font(.callout)
                Picker("판본", selection: $selectedVersionID) {
                    ForEach(versions) { version in
                        Text("v\(version.version) · \(version.pageCount)쪽")
                            .tag(Optional(version.materialID))
                    }
                }
                .labelsHidden()
                .frame(width: 150)
                .controlSize(.small)
                Spacer(minLength: 0)
            }
            if let selectedVersion, selectedVersion.materialID != versions.first?.materialID {
                Label("이전 판본 · 최신 v\(versions.first?.version ?? 1)",
                      systemImage: "clock.arrow.circlepath")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let summary {
                DisclosureGroup(isExpanded: $showChanges) {
                    VStack(alignment: .leading, spacing: 6) {
                        if summary.pageDelta > 0 {
                            Text("\(summary.pageDelta)쪽 증가 · \(summary.previousPages) → \(summary.currentPages)쪽")
                        } else if summary.pageDelta < 0 {
                            Text("\(-summary.pageDelta)쪽 감소 · \(summary.previousPages) → \(summary.currentPages)쪽")
                        } else {
                            Text("쪽수 동일 · 내용 변경")
                        }
                        if isComparing {
                            ProgressView("페이지 비교 중")
                                .controlSize(.small)
                        } else if let visualDiff, visualDiff.locationsCertain {
                            if !visualDiff.addedPages.isEmpty {
                                Text("추가: \(visualDiff.addedPages.map(String.init).joined(separator: ", "))쪽")
                            }
                            if !visualDiff.removedPages.isEmpty {
                                Text("삭제: \(visualDiff.removedPages.map(String.init).joined(separator: ", "))쪽")
                            }
                            if !visualDiff.changedPages.isEmpty {
                                Text("변경: \(visualDiff.changedPages.map(String.init).joined(separator: ", "))쪽")
                            }
                        } else if !summary.definitelyAddedPages.isEmpty {
                            Text("추가 확인: \(summary.definitelyAddedPages.map(String.init).joined(separator: ", "))쪽")
                        } else {
                            Text("페이지 대응이 불확실해 변경 위치를 확인할 수 없습니다.")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Text("변경 내역 · v\(summary.previousVersion) → v\(summary.currentVersion)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
