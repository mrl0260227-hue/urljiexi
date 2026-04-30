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
                    self.errorMessage = "未识别到清晰字幕，请换一个字幕更清晰的视频再试。"
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

        let sampleCount = max(8, min(24, Int(duration / 1.2)))
        var lines: [String] = []

        for i in 1...sampleCount {
            let second = min(duration - 0.08, Double(i) * duration / Double(sampleCount + 1))
            guard second > 0 else { continue }

            let time = CMTime(seconds: second, preferredTimescale: 600)

            do {
                let fullImage = try generator.copyCGImage(at: time, actualTime: nil)
                guard let subtitleArea = cropBottomArea(from: fullImage) else { continue }

                let recognized = recognizeText(in: subtitleArea)
                for raw in recognized {
                    let cleaned = normalizeLine(raw)
                    if isLikelySubtitle(cleaned) {
                        lines.append(cleaned)
                    }
                }
            } catch {
                continue
            }
        }

        let merged = mergeLines(lines)
        return merged.joined(separator: "\n")
    }

    private func cropBottomArea(from image: CGImage) -> CGImage? {
        let width = image.width
        let height = image.height

        let cropHeight = Int(Double(height) * 0.42)
        let cropY = 0
        let rect = CGRect(x: 0, y: cropY, width: width, height: cropHeight)

        return image.cropping(to: rect)
    }

    private func recognizeText(in image: CGImage) -> [String] {
        var results: [String] = []

        let request = VNRecognizeTextRequest { request, _ in
            guard let observations = request.results as? [VNRecognizedTextObservation] else { return }
            for item in observations {
                if let top = item.topCandidates(1).first?.string {
                    results.append(top)
                }
            }
        }

        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.minimumTextHeight = 0.018

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try? handler.perform([request])

        return results
    }

    private func normalizeLine(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "|", with: "")
            .replacingOccurrences(of: "_", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isLikelySubtitle(_ line: String) -> Bool {
        guard line.count >= 2 else { return false }

        let hasMeaningful = line.range(of: "[\\p{Han}A-Za-z0-9]", options: .regularExpression) != nil
        let onlySymbols = line.range(of: "^[\\p{P}\\p{S}\\s]+$", options: .regularExpression) != nil

        if !hasMeaningful || onlySymbols { return false }

        if line.range(of: "^[A-Z0-9\\s\\.:\\-]{10,}$", options: .regularExpression) != nil {
            return false
        }

        return true
    }

    private func mergeLines(_ lines: [String]) -> [String] {
        var merged: [String] = []

        for line in lines {
            guard !line.isEmpty else { continue }

            if let last = merged.last {
                let n1 = normalizeForCompare(last)
                let n2 = normalizeForCompare(line)
                if n1 == n2 { continue }
            }

            merged.append(line)
        }

        return merged
    }

    private func normalizeForCompare(_ s: String) -> String {
        s.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression).lowercased()
    }
}
