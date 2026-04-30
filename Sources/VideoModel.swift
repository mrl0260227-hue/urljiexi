import Foundation

struct VideoItem: Identifiable, Codable {
    var id = UUID()
    let relativePath: String
    let downloadDate: Date
    var extractedText: String?

    var localURL: URL {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documentsURL.appendingPathComponent(relativePath)
    }

    var fileName: String {
        relativePath
    }
}
