import Foundation

struct VideoItem: Identifiable, Codable {
    var id = UUID()
    let localURL: URL
    let downloadDate: Date
    var extractedText: String?
    
    var fileName: String {
        localURL.lastPathComponent
    }
}
