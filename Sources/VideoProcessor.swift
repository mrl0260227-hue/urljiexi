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

    private struct OCRLine {
        let text: String
        let y: CGFloat
        let confidence: Float
    }

    private func runSubtitleOCR(videoURL: URL) -> String {
        let asset = AVAsset(url: videoURL)
        let duration = CMTimeGetSeconds(asset.duration)
        guard duration.isFinite, duration > 0 else { return "" }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        let interval: Double = duration <= 20 ? 0.30 : 0.45
        let maxFrames = 260

        let timeline = buildSampleTimes(duration: duration, interval: interval, maxFrames: maxFrames)
        var subtitleLines: [String] = []

        for second in timeline {
            let time = CMTime(seconds: second, preferredTimescale: 600)

            do {
                let frame = try generator.copyCGImage(at: time, actualTime: nil)
                guard let subtitleRegion = cropSubtitleRegion(from: frame) else { continue }

                let ocrLines = recognizeSubtitleLines(in: subtitleRegion)
                guard let frameSubtitle = composeFrameSubtitle(from: ocrLines) else { continue }

                appendIfNew(frameSubtitle, to: &subtitleLines)
            } catch {
                continue
            }
        }

        return subtitleLines.joined(separator: "\n")
    }

    private func buildSampleTimes(duration: Double, interval: Double, maxFrames: Int) -> [Double] {
        var times: [Double] = []
        var t = 0.15

        while t < duration - 0.05 && times.count < maxFrames {
            times.append(t)
            t += interval
        }

        // If video is very short and no points generated.
        if times.isEmpty {
            times = [max(0.01, min(duration - 0.01, duration * 0.5))]
        }

        return times
    }

    private func cropSubtitleRegion(from image: CGImage) -> CGImage? {
        let width = image.width
        let height = image.height

        // Keep a wider bottom area to avoid cutting two-line subtitles.
        let y = Int(Double(height) * 0.62)
        let h = max(1, Int(Double(height) * 0.34))
        let rect = CGRect(x: 0, y: y, width: width, height: h)

        return image.cropping(to: rect)
    }

    private func recognizeSubtitleLines(in image: CGImage) -> [OCRLine] {
        var lines: [OCRLine] = []

        let request = VNRecognizeTextRequest { request, _ in
            guard let observations = request.results as? [VNRecognizedTextObservation] else { return }

            for observation in observations {
                guard let top = observation.topCandidates(1).first else { continue }
                let cleaned = self.normalizeLine(top.string)
                guard self.isUsefulSubtitle(cleaned) else { continue }

                lines.append(OCRLine(text: cleaned, y: observation.boundingBox.midY, confidence: top.confidence))
            }
        }

        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.minimumTextHeight = 0.018

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try? handler.perform([request])

        return lines
    }

    private func composeFrameSubtitle(from lines: [OCRLine]) -> String? {
        guard !lines.isEmpty else { return nil }

        // Sort from upper line to lower line in the cropped region.
        let sorted = lines.sorted {
            if abs($0.y - $1.y) > 0.03 { return $0.y > $1.y }
            return $0.confidence > $1.confidence
        }

        // Keep up to two lines per frame (common subtitle layout).
        var selected: [String] = []
        for line in sorted {
            if !selected.contains(line.text) {
                selected.append(line.text)
            }
            if selected.count >= 2 { break }
        }

        guard !selected.isEmpty else { return nil }
        return selected.joined(separator: " ")
    }

    private func appendIfNew(_ candidate: String, to lines: inout [String]) {
        let normalizedCandidate = normalizeKey(candidate)
        guard !normalizedCandidate.isEmpty else { return }

        if let last = lines.last {
            let normalizedLast = normalizeKey(last)

            // Adjacent near-duplicate suppression only.
            if normalizedCandidate == normalizedLast {
                return
            }

            if normalizedCandidate.count >= 6 && normalizedLast.contains(normalizedCandidate) {
                return
            }

            if normalizedLast.count >= 6 && normalizedCandidate.contains(normalizedLast) {
                lines[lines.count - 1] = candidate
                return
            }
        }

        lines.append(candidate)

        // Safety cap for very long videos.
        if lines.count > 180 {
            lines.removeFirst(lines.count - 180)
        }
    }

    private func normalizeLine(_ raw: String) -> String {
        var text = raw
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        text = text.replacingOccurrences(of: "【", with: "")
        text = text.replacingOccurrences(of: "】", with: "")
        text = text.replacingOccurrences(of: "|", with: "")

        return text
    }

    private func isUsefulSubtitle(_ line: String) -> Bool {
        guard line.count >= 2 else { return false }

        if line.range(of: "^[\\p{P}\\p{S}\\s]+$", options: .regularExpression) != nil {
            return false
        }

        if line.range(of: "[\\p{Han}A-Za-z0-9]", options: .regularExpression) == nil {
            return false
        }

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
