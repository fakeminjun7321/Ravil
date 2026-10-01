import SwiftUI

struct ExamScopeDetailView: View {
    let model: AppModel
    let scope: ExamScopeItem
    let onCardsChanged: () -> Void
    @State private var ranges: [ExamMaterialRange] = []
    @State private var cards: [QuizCardItem] = []
    @State private var selectedMaterialID: String?
    @State private var selectedPage = 1
    @State private var question = ""
    @State private var answer = ""
    @State private var currentCard: QuizCardItem?
    @State private var showAnswer = false
    @State private var seenIDs: Set<String> = []
    @State private var sessionMessage = ""
    @State private var rangeToRebase: ExamMaterialRange?

    private var selectedRange: ExamMaterialRange? {
        ranges.first { $0.materialID == selectedMaterialID }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(scope.title).font(.largeTitle.bold())
                    if let date = scope.examDate { Text("시험일 \(date)").foregroundStyle(.secondary) }
                }
                sourceList
                Divider()
                reviewSection
                Divider()
                cardEditor
            }
            .padding(26)
            .frame(maxWidth: 850, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .task(id: scope.id) { reload() }
        .onChange(of: selectedMaterialID) { _, id in
            if let range = ranges.first(where: { $0.materialID == id }) {
                selectedPage = range.startPage
            }
        }
        .sheet(item: $rangeToRebase) { range in
            ExamRangeRebaseView(model: model, scopeID: scope.id, range: range) {
                rangeToRebase = nil
                selectedMaterialID = nil
                currentCard = nil
                reload()
                onCardsChanged()
            }
        }
    }

    private var sourceList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("시험 범위 자료").font(.title3.bold())
            ForEach(ranges) { range in
                HStack(spacing: 9) {
                    Image(systemName: range.sourceIsCurrent ? "doc.text" : "exclamationmark.triangle")
                        .foregroundStyle(range.sourceIsCurrent ? Color.secondary : Color.orange)
                    Text(range.title)
                    Spacer()
                    Text("\(range.startPage)~\(range.endPage)쪽")
                        .foregroundStyle(.secondary)
                    if range.replacementMaterialID != nil {
                        Button("새 판본 범위 지정") { rangeToRebase = range }
                            .font(.caption)
                    }
                }
            }
            if ranges.contains(where: { !$0.sourceIsCurrent }) {
                Text("새 Goodnotes 판본이 들어온 자료가 있습니다. 페이지 연결을 확인하기 전에는 새 카드를 만들지 않습니다.")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private var reviewSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("범위 훑기").font(.title3.bold())
                Spacer()
                Text("카드 \(cards.count)개")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("첫 순회에서는 아직 풀지 않은 카드를 우선합니다. 방금 틀린 카드가 몇 분 뒤 다른 범위를 가리지 않습니다.")
                .font(.caption).foregroundStyle(.secondary)
            if let card = currentCard {
                VStack(alignment: .leading, spacing: 15) {
                    if !card.sourceIsCurrent {
                        Label("원본 PDF 판본이 바뀌었습니다. 현재 자료와 대조해 주세요.",
                              systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    Text(card.question).font(.title3.weight(.medium))
                    if showAnswer {
                        Divider()
                        Text(card.answer).textSelection(.enabled)
                        HStack {
                            ForEach(QuizGrade.allCases, id: \.self) { grade in
                                Button(grade.rawValue) { record(grade, for: card) }
                                    .buttonStyle(.bordered)
                            }
                        }
                    } else {
                        Button("답 보기") { showAnswer = true }
                            .buttonStyle(.borderedProminent)
                    }
                    Text("출처: \(card.materialTitle) v\(card.sourceVersion) · \(card.sourcePage)쪽")
                        .font(.caption).foregroundStyle(.secondary)
                    if let path = card.materialPath {
                        DisclosureGroup("출처 페이지 보기") {
                            PDFMaterialPreview(url: URL(fileURLWithPath: path),
                                               initialPage: card.sourcePage)
                                .id(card.id)
                                .frame(minHeight: 430)
                        }
                    }
                }
                .padding(18)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            } else {
                if !sessionMessage.isEmpty {
                    Text(sessionMessage).foregroundStyle(.secondary)
                }
                Button("범위 훑기 시작") { startReview() }
                    .disabled(!cards.contains(where: \.sourceIsCurrent))
            }
        }
    }

    private var cardEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("출처가 연결된 카드 만들기").font(.title3.bold())
            Text("자동 인식문을 그대로 정답으로 쓰지 않고, 원본을 확인한 뒤 문제와 답을 직접 저장합니다.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("자료", selection: $selectedMaterialID) {
                Text("자료 선택").tag(String?.none)
                ForEach(ranges.filter(\.sourceIsCurrent)) { range in
                    Text("\(range.subject) · \(range.title)")
                        .tag(Optional(range.materialID))
                }
            }
            if let selectedRange {
                Stepper("출처 \(selectedPage)쪽", value: $selectedPage,
                        in: selectedRange.startPage...selectedRange.endPage)
            }
            Text("문제").font(.subheadline.weight(.medium))
            TextEditor(text: $question)
                .frame(height: 90)
                .padding(6)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
            Text("답").font(.subheadline.weight(.medium))
            TextEditor(text: $answer)
                .frame(height: 110)
                .padding(6)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
            Button("카드 저장") {
                guard let materialID = selectedMaterialID else { return }
                if model.addQuizCard(scopeID: scope.id, materialID: materialID,
                                     page: selectedPage, question: question, answer: answer) {
                    question = ""
                    answer = ""
                    reload()
                    onCardsChanged()
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(selectedMaterialID == nil || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      || answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func reload() {
        ranges = model.examMaterials(scopeID: scope.id)
        cards = model.quizCards(scopeID: scope.id)
        if selectedMaterialID == nil || !ranges.contains(where: { $0.materialID == selectedMaterialID && $0.sourceIsCurrent }) {
            selectedMaterialID = ranges.first(where: \.sourceIsCurrent)?.materialID
            selectedPage = ranges.first(where: \.sourceIsCurrent)?.startPage ?? 1
        }
    }

    private func startReview() {
        seenIDs = []
        sessionMessage = ""
        showAnswer = false
        currentCard = model.nextQuizCard(scopeID: scope.id, excluding: seenIDs)
        if currentCard == nil { sessionMessage = "이번에 새로 훑거나 다시 볼 약점 카드가 없습니다." }
    }

    private func record(_ grade: QuizGrade, for card: QuizCardItem) {
        guard model.recordQuizReview(cardID: card.id, grade: grade) else { return }
        seenIDs.insert(card.id)
        cards = model.quizCards(scopeID: scope.id)
        onCardsChanged()
        showAnswer = false
        currentCard = model.nextQuizCard(scopeID: scope.id, excluding: seenIDs)
        if currentCard == nil { sessionMessage = "이번 범위의 첫 순회와 약점 확인을 마쳤습니다." }
    }
}
