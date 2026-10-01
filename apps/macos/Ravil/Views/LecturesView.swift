import SwiftUI

struct LecturesView: View {
    @Bindable var model: AppModel

    private var dates: [String] {
        Array(Set(model.filteredLectures.map(\.date))).sorted(by: >)
    }

    var body: some View {
        HSplitView {
            List(selection: $model.selectedLectureID) {
                ForEach(dates, id: \.self) { date in
                    Section(date) {
                        ForEach(model.filteredLectures.filter { $0.date == date }) { lecture in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: lecture.symbol)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 16)
                                    .padding(.top, 2)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(lecture.title)
                                        .font(.body.weight(.medium))
                                        .lineLimit(1)
                                    Text(lecture.displaySubjectName)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            .padding(.vertical, 6)
                            .help(lecture.title)
                            .tag(lecture.id)
                        }
                    }
                }
            }
            .listStyle(.inset)
            .frame(minWidth: 200, idealWidth: 255, maxWidth: 330)
            .onChange(of: model.selectedLectureID) { _, value in
                if let value { model.selectLecture(value) }
            }
            Group {
                if let lecture = model.selectedLecture,
                   model.filteredLectures.contains(where: { $0.id == lecture.id }) {
                    LectureDetailView(model: model, lecture: lecture)
                        .id(lecture.id)
                } else if let groupID = model.selectedSubjectGroupID,
                          let group = model.subjectGroups.first(where: { $0.id == groupID }) {
                    ContentUnavailableView("\(group.title)에 강의가 없습니다", systemImage: "folder")
                } else {
                    ContentUnavailableView("강의를 선택하세요", systemImage: "waveform")
                }
            }
            .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
