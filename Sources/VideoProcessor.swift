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
        let strict = extractPass(videoURL: videoURL, strict: true)
        if !strict.isEmpty { return strict }

        // Fallback: relax region/geometry/semantic thresholds to avoid empty results.
        return extractPass(videoURL: videoURL, strict: false)
    }

    private func extractPass(videoURL: URL, strict: Bool) -> String {
        let asset = AVAsset(url: videoURL)
        let duration = CMTimeGetSeconds(asset.duration)
        guard duration.isFinite, duration > 0 else { return "" }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        let interval: Double = strict ? (duration <= 20 ? 0.28 : 0.40) : (duration <= 20 ? 0.22 : 0.32)
        let maxFrames = strict ? 280 : 320
        let timeline = buildSampleTimes(duration: duration, interval: interval, maxFrames: maxFrames)

        var subtitleLines: [String] = []
        var keyCount: [String: Int] = [:]

        for second in timeline {
            let time = CMTime(seconds: second, preferredTimescale: 600)

            do {
                let frame = try generator.copyCGImage(at: time, actualTime: nil)
                guard let subtitleRegion = cropSubtitleRegion(from: frame, strict: strict) else { continue }

                let ocrLines = recognizeSubtitleLines(in: subtitleRegion, strict: strict)
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
        let dynamicThreshold = strict ? 0.50 : 0.72
        let dynamicLines = subtitleLines.filter { line in
            let key = normalizeKey(line)
            guard !key.isEmpty else { return false }
            let ratio = Double(keyCount[key, default: 0]) / Double(frameTotal)
            return ratio <= dynamicThreshold
        }

        let candidateLines = dynamicLines.isEmpty ? subtitleLines : dynamicLines
        let semanticLines = filterSemanticLines(candidateLines, strict: strict)
        if !semanticLines.isEmpty {
            return semanticLines.joined(separator: "\n")
        }

        // Final fallback: keep non-interference lines to avoid empty result.
        let fallback = candidateLines.filter { !containsInterference($0.lowercased()) }
        return dedupPreserveOrder(fallback).joined(separator: "\n")
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

    private func cropSubtitleRegion(from image: CGImage, strict: Bool) -> CGImage? {
        let width = image.width
        let height = image.height

        let yRatio = strict ? 0.78 : 0.72
        let hRatio = strict ? 0.18 : 0.24

        let y = Int(Double(height) * yRatio)
        let h = max(1, Int(Double(height) * hRatio))
        let rect = CGRect(x: 0, y: y, width: width, height: h)

        return image.cropping(to: rect)
    }

    private func recognizeSubtitleLines(in image: CGImage, strict: Bool) -> [OCRLine] {
        var lines: [OCRLine] = []

        let request = VNRecognizeTextRequest { request, _ in
            guard let observations = request.results as? [VNRecognizedTextObservation] else { return }

            for observation in observations {
                guard let top = observation.topCandidates(1).first else { continue }

                let cleaned = self.normalizeLine(top.string)
                guard self.isUsefulSubtitle(cleaned) else { continue }

                let box = observation.boundingBox

                let midXMin: CGFloat = strict ? 0.10 : 0.05
                let midXMax: CGFloat = strict ? 0.90 : 0.95
                let minWidth: CGFloat = strict ? 0.14 : 0.10
                let maxYLimit: CGFloat = strict ? 0.45 : 0.70

                if box.midX < midXMin || box.midX > midXMax { continue }
                if box.width < minWidth { continue }
                if box.maxY > maxYLimit { continue }

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
        request.minimumTextHeight = strict ? 0.015 : 0.012

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try? handler.perform([request])

        return lines
    }

    private func composeFrameSubtitle(from lines: [OCRLine]) -> String? {
        guard !lines.isEmpty else { return nil }

        let sorted = lines.sorted {
            if abs($0.maxY - $1.maxY) > 0.02 { return $0.maxY < $1.maxY }
            if abs($0.width - $1.width) > 0.01 { return $0.width > $1.width }
            if abs($0.midX - $1.midX) > 0.01 { return abs($0.midX - 0.5) < abs($1.midX - 0.5) }
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

        if lines.count > 220 {
            lines.removeFirst(lines.count - 220)
        }
    }

    private func filterSemanticLines(_ lines: [String], strict: Bool) -> [String] {
        let speechHints = [
            "我", "你", "他", "她", "它", "我们", "大家", "这", "那", "就", "了", "在", "有", "很", "也", "都",
            "还", "要", "会", "可以", "今天", "现在", "这个", "那个", "就是", "真的", "特别", "推荐", "觉得",
            "然后", "所以", "因为", "来到", "来", "吃", "点", "看", "买", "做", "处理", "现炒", "口味", "干净", "入味"
        ]

        var kept: [String] = []

        for line in lines {
            let lower = line.lowercased()
            let normalized = normalizeKey(line)
            guard !normalized.isEmpty else { continue }

            if containsInterference(lower) {
                continue
            }

            var score = 0

            if line.count >= 4 && line.count <= 30 { score += 1 }
            if line.range(of: "[\\p{Han}]", options: .regularExpression) != nil { score += 2 }

            if speechHints.contains(where: { line.contains($0) }) {
                score += 2
            }

            if line.range(of: "[。！？,.!?]$", options: .regularExpression) != nil {
                score += 1
            }

            let digitCount = line.filter { $0.isNumber }.count
            if digitCount >= 4 { score -= 1 }

            if line.range(of: "^[0-9A-Za-z\\s\\*#\\-]+$", options: .regularExpression) != nil {
                score -= 2
            }

            let passScore = strict ? 2 : 1
            if score >= passScore {
                appendIfNew(line, to: &kept)
            }
        }

        return kept
    }

    private func containsInterference(_ lower: String) -> Bool {
        let interferenceKeywords = [
            "welcome", "telcome", "扫码", "店内", "门店", "营业", "地址", "电话", "导航", "广告", "团购",
            "地铁", "号口", "楼层", "新街口", "3f", "4f", "b1", "b2", "*welcome"
        ]
        return interferenceKeywords.contains(where: { lower.contains($0) })
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

        return true
    }

    private func normalizeKey(_ line: String) -> String {
        line
            .replacingOccurrences(of: "[^\\p{Han}A-Za-z0-9]", with: "", options: .regularExpression)
            .lowercased()
    }

    private func dedupPreserveOrder(_ lines: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for line in lines {
            let key = normalizeKey(line)
            if key.isEmpty { continue }
            if seen.insert(key).inserted {
                out.append(line)
            }
        }
        return out
    }
}
