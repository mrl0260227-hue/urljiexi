import Foundation
import AVFoundation
import Vision

final class VideoProcessor: ObservableObject {
    @Published var isProcessing = false
    @Published var processedText = ""
    @Published var errorMessage: String?

    func extractSubtitleText(videoURL: URL) {
        DispatchQueue.main.async {
            self.isProcessing = true
            self.processedText = ""
            self.errorMessage = nil
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let text = self.runSubtitleOCR(videoURL: videoURL)

            DispatchQueue.main.async {
                if text.isEmpty {
                    self.errorMessage = "未提取到中英文字幕，请换更清晰视频再试。"
                    self.processedText = ""
                } else {
                    self.processedText = text
                }
                self.isProcessing = false
            }
        }
    }

    private func runSubtitleOCR(videoURL: URL) -> String {
        let asset = AVAsset(url: videoURL)
        let duration = CMTimeGetSeconds(asset.duration)
        guard duration.isFinite, duration > 0 else { return "" }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        let sampleCount = max(12, min(36, Int(duration / 0.8)))

        var frequencies: [String: Int] = [:]
        var displayTextByKey: [String: String] = [:]
        var firstSeenOrder: [String: Int] = [:]
        var index = 0

        for i in 1...sampleCount {
            let second = min(duration - 0.05, Double(i) * duration / Double(sampleCount + 1))
            guard second > 0 else { continue }
            let time = CMTime(seconds: second, preferredTimescale: 600)

            do {
                let frame = try generator.copyCGImage(at: time, actualTime: nil)
                guard let subtitleRegion = cropSubtitleRegion(from: frame) else { continue }

                let lines = recognizeSubtitleLines(in: subtitleRegion)
                for raw in lines {
                    let cleaned = normalizeLine(raw)
                    guard isUsefulSubtitle(cleaned) else { continue }

                    let key = normalizeKey(cleaned)
                    guard !key.isEmpty else { continue }

                    frequencies[key, default: 0] += 1
                    if displayTextByKey[key] == nil {
                        displayTextByKey[key] = cleaned
                        firstSeenOrder[key] = index
                        index += 1
                    }
                }
            } catch {
                continue
            }
        }

        guard !frequencies.isEmpty else { return "" }

        // Prefer stable lines (appear in multiple frames), then keep early timeline order.
        var keys = frequencies.keys.filter { frequencies[$0, default: 0] >= 2 }

        if keys.isEmpty {
            keys = Array(
                frequencies
                    .sorted { lhs, rhs in
                        if lhs.value != rhs.value { return lhs.value > rhs.value }
                        return (firstSeenOrder[lhs.key] ?? .max) < (firstSeenOrder[rhs.key] ?? .max)
                    }
                    .prefix(8)
                    .map { $0.key }
            )
        } else {
            keys.sort { (firstSeenOrder[$0] ?? .max) < (firstSeenOrder[$1] ?? .max) }
            keys = Array(keys.prefix(12))
        }

        let lines = keys.compactMap { displayTextByKey[$0] }
        return lines.joined(separator: "\n")
    }

    private func cropSubtitleRegion(from image: CGImage) -> CGImage? {
        let width = image.width
        let height = image.height

        // Subtitle is usually near the lower part in short videos.
        let y = Int(Double(height) * 0.70)
        let h = max(1, Int(Double(height) * 0.24))
        let rect = CGRect(x: 0, y: y, width: width, height: h)

        return image.cropping(to: rect)
    }

    private func recognizeSubtitleLines(in image: CGImage) -> [String] {
        var results: [String] = []

        let request = VNRecognizeTextRequest { request, _ in
            guard let observations = request.results as? [VNRecognizedTextObservation] else { return }

            for observation in observations {
                if let top = observation.topCandidates(1).first?.string {
                    results.append(top)
                }
            }
        }

        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.minimumTextHeight = 0.022

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try? handler.perform([request])

        return results
    }

    private func normalizeLine(_ raw: String) -> String {
        var text = raw
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Remove obvious bracket noise around subtitles.
        text = text.replacingOccurrences(of: "【", with: "")
        text = text.replacingOccurrences(of: "】", with: "")

        return text
    }

    private func isUsefulSubtitle(_ line: String) -> Bool {
        guard line.count >= 2 else { return false }

        // Skip pure symbols or isolated garbage.
        if line.range(of: "^[\\p{P}\\p{S}\\s]+$", options: .regularExpression) != nil {
            return false
        }

        // Keep only lines containing Chinese/English/number.
        if line.range(of: "[\\p{Han}A-Za-z0-9]", options: .regularExpression) == nil {
            return false
        }

        // Skip watermark-like trivial lines.
        let lower = line.lowercased()
        if lower == "广告" || lower == "ad" {
            return false
        }

        return true
    }

    private func normalizeKey(_ line: String) -> String {
        line
            .replacingOccurrences(of: "[^\\p{Han}A-Za-z0-9]", with: "", options: .regularExpression)
            .lowercased()
    }
}
