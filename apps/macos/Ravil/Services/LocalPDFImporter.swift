import Foundation

/// A separate, serial connection keeps PDF parsing and hashing off MainActor.
/// The existing import transaction still owns deduplication, versions and links.
actor LocalPDFImporter {
    static let shared = LocalPDFImporter()

    func importPDF(from source: URL, databaseURL: URL, courseID: String?,
                   lectureID: String?, subjectName: String?) throws -> MaterialItem {
        let database = try LibraryDatabase(location: databaseURL, importLegacy: false)
        return try database.importLocalPDF(from: source, courseID: courseID,
                                           lectureID: lectureID, subjectName: subjectName)
    }
}
