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
                    self.errorMessage = "未提取到口播字幕，请换更清晰视频再试。"
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
        let maxY: CGFloat
        let midX: CGFloat
        let width: CGFloat
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
        var keyCount: [String: Int] = [:]

        for second in timeline {
            let time = CMTime(seconds: second, preferredTimescale: 600)

            do {
                let frame = try generator.copyCGImage(at: time, actualTime: nil)
                guard let subtitleRegion = cropSubtitleRegion(from: frame) else { continue }

                let ocrLines = recognizeSubtitleLines(in: subtitleRegion)
                guard let frameSubtitle = composeFrameSubtitle(from: ocrLines) else { continue }

                appendIfNew(frameSubtitle, to: &subtitleLines)
                let key = normalizeKey(frameSubtitle)
                if !key.isEmpty {
                    keyCount[key, default: 0] += 1
                }
            } catch {
                continue
            }
        }

        guard !subtitleLines.isEmpty else { return "" }

        let frameTotal = max(1, timeline.count)
        let dynamicLines = subtitleLines.filter { line in
            let key = normalizeKey(line)
            guard !key.isEmpty else { return false }
            let ratio = Double(keyCount[key, default: 0]) / Double(frameTotal)
            return ratio <= 0.55
        }

        let candidateLines = dynamicLines.isEmpty ? subtitleLines : dynamicLines
        let semanticLines = filterSemanticLines(candidateLines)

        if semanticLines.isEmpty {
            return candidateLines.joined(separator: "\n")
        }

        return semanticLines.joined(separator: "\n")
    }

    private func buildSampleTimes(duration: Double, interval: Double, maxFrames: Int) -> [Double] {
        var times: [Double] = []
        var t = 0.15

        while t < duration - 0.05 && times.count < maxFrames {
            times.append(t)
            t += interval
        }

        if times.isEmpty {
            times = [max(0.01, min(duration - 0.01, duration * 0.5))]
        }

        return times
    }

    private func cropSubtitleRegion(from image: CGImage) -> CGImage? {
        let width = image.width
        let height = image.height

        let y = Int(Double(height) * 0.74)
        let h = max(1, Int(Double(height) * 0.20))
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

                let box = observation.boundingBox

                if box.midX < 0.12 || box.midX > 0.88 { continue }
                if box.width < 0.20 { continue }
                if box.maxY > 0.55 { continue }

                lines.append(
                    OCRLine(
                        text: cleaned,
                        maxY: box.maxY,
                        midX: box.midX,
                        width: box.width,
                        confidence: top.confidence
                    )
                )
            }
        }

        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.minimumTextHeight = 0.02

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try? handler.perform([request])

        return lines
    }

    private func composeFrameSubtitle(from lines: [OCRLine]) -> String? {
        guard !lines.isEmpty else { return nil }

        let sorted = lines.sorted {
            if abs($0.maxY - $1.maxY) > 0.02 { return $0.maxY > $1.maxY }
            if abs($0.midX - $1.midX) > 0.01 { return abs($0.midX - 0.5) < abs($1.midX - 0.5) }
            if abs($0.width - $1.width) > 0.01 { return $0.width > $1.width }
            return $0.confidence > $1.confidence
        }

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

        if lines.count > 180 {
            lines.removeFirst(lines.count - 180)
        }
    }

    private func filterSemanticLines(_ lines: [String]) -> [String] {
        let interferenceKeywords = [
            "welcome", "扫码", "店内", "门店", "营业", "地址", "电话", "导航", "广告", "团购",
            "地铁", "号口", "楼层", "f", "b1", "b2", "3f", "4f", "*welcome"
        ]

        let speechHints = [
            "我", "你", "他", "她", "它", "我们", "大家", "这", "那", "就", "了", "在", "有", "很", "也", "都",
            "还", "要", "会", "可以", "今天", "现在", "这个", "那个", "就是", "真的", "特别", "推荐", "觉得",
            "然后", "所以", "因为", "来到", "来", "吃", "点", "看", "买", "做", "处理", "现炒", "口味"
        ]

        var kept: [String] = []

        for line in lines {
            let lower = line.lowercased()
            let normalized = normalizeKey(line)
            guard !normalized.isEmpty else { continue }

            var score = 0

            if line.count >= 6 && line.count <= 26 { score += 1 }
            if line.range(of: "[\\p{Han}]", options: .regularExpression) != nil { score += 1 }

            if speechHints.contains(where: { line.contains($0) }) {
                score += 2
            }

            if line.range(of: "[。！？,.!?]$", options: .regularExpression) != nil {
                score += 1
            }

            if interferenceKeywords.contains(where: { lower.contains($0) }) {
                score -= 3
            }

            let digitCount = line.filter { $0.isNumber }.count
            if digitCount >= 4 { score -= 1 }

            if line.range(of: "^[0-9A-Za-z\\s\\*#\\-]+$", options: .regularExpression) != nil {
                score -= 2
            }

            // Keep line if likely spoken subtitle.
            if score >= 1 {
                appendIfNew(line, to: &kept)
            }
        }

        return kept
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
