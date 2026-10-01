import Foundation

struct AltFolderSnapshot {
    let sourceURL: URL
    let workspaceName: String
    let folders: [AltFolderMetadata]
    let notes: [AltNoteMetadata]
}

struct AltFolderMetadata: Identifiable {
    let id: String
    let name: String
    let parentID: String?
    let colorHue: Int?
    let noteCount: Int
}

struct AltNoteMetadata: Identifiable {
    let id: String
    let title: String
    let date: String
    let type: String
    let folderID: String?
}
