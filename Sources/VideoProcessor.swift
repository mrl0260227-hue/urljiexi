import Foundation
import AVFoundation
import Speech
import Vision

final class VideoProcessor: ObservableObject {
    @Published var isProcessing = false
    @Published var processedText = ""
    @Published var errorMessage: String?

    private var recognitionTask: SFSpeechRecognitionTask?

    deinit {
        recognitionTask?.cancel()
    }

    // 主入口：先 OCR（视频画面文字），OCR 为空时回退语音识别
    func extractTextFromVideo(videoURL: URL, completion: ((String) -> Void)? = nil) {
        DispatchQueue.main.async {
            self.isProcessing = true
            self.processedText = ""
            self.errorMessage = nil
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let ocrResult = self.extractTextByOCR(from: videoURL)

            if !ocrResult.isEmpty {
                self.finishSuccess(ocrResult, completion: completion)
                return
            }

            self.extractTextBySpeech(from: videoURL) { result in
                switch result {
                case .success(let text):
                    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        self.finishFailure("未识别到可用文字（画面和语音都为空）")
                    } else {
                        self.finishSuccess(text, completion: completion)
                    }
                case .failure(let error):
                    self.finishFailure(error.localizedDescription)
                }
            }
        }
    }

    // MARK: - OCR

    private func extractTextByOCR(from videoURL: URL) -> String {
        let asset = AVAsset(url: videoURL)
        let duration = CMTimeGetSeconds(asset.duration)
        guard duration.isFinite, duration > 0 else { return "" }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        let sampleCount = max(4, min(14, Int(duration / 1.5)))
        var allLines: [String] = []
        var alphaNumericLines: [String] = []

        for i in 1...sampleCount {
            let second = min(duration - 0.05, Double(i) * duration / Double(sampleCount + 1))
            guard second > 0 else { continue }

            let time = CMTime(seconds: second, preferredTimescale: 600)

            do {
                let cgImage = try generator.copyCGImage(at: time, actualTime: nil)
                let lines = recognizeText(in: cgImage)

                for line in lines {
                    let cleaned = normalizeLine(line)
                    guard !cleaned.isEmpty else { continue }
                    allLines.append(cleaned)

                    if containsAlphaNumeric(cleaned) {
                        alphaNumericLines.append(cleaned)
                    }
                }
            } catch {
                continue
            }
        }

        let prioritized = uniquePreservingOrder(alphaNumericLines)
        if !prioritized.isEmpty {
            return prioritized.joined(separator: "\n")
        }

        let fallback = uniquePreservingOrder(allLines)
        return fallback.joined(separator: "\n")
    }

    private func recognizeText(in image: CGImage) -> [String] {
        var captured: [String] = []

        let request = VNRecognizeTextRequest { request, _ in
            guard let observations = request.results as? [VNRecognizedTextObservation] else { return }
            for observation in observations {
                if let best = observation.topCandidates(1).first?.string {
                    captured.append(best)
                }
            }
        }

        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US", "zh-Hans"]
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try? handler.perform([request])

        return captured
    }

    private func normalizeLine(_ line: String) -> String {
        line.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func containsAlphaNumeric(_ text: String) -> Bool {
        text.range(of: "[A-Za-z0-9]", options: .regularExpression) != nil
    }

    // MARK: - Speech fallback

    private func extractTextBySpeech(from videoURL: URL, completion: @escaping (Result<String, Error>) -> Void) {
        exportAudioTrack(from: videoURL) { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let audioURL):
                self.requestSpeechAuthorization { authorized in
                    guard authorized else {
                        try? FileManager.default.removeItem(at: audioURL)
                        completion(.failure(NSError(
                            domain: "VideoProcessor",
                            code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "未授予语音识别权限"]
                        )))
                        return
                    }

                    let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
                    guard let recognizer = recognizer, recognizer.isAvailable else {
                        try? FileManager.default.removeItem(at: audioURL)
                        completion(.failure(NSError(
                            domain: "VideoProcessor",
                            code: 2,
                            userInfo: [NSLocalizedDescriptionKey: "语音识别当前不可用"]
                        )))
                        return
                    }

                    let request = SFSpeechURLRecognitionRequest(url: audioURL)
                    request.shouldReportPartialResults = false

                    self.recognitionTask?.cancel()
                    self.recognitionTask = recognizer.recognitionTask(with: request) { result, error in
                        if let error = error {
                            try? FileManager.default.removeItem(at: audioURL)
                            completion(.failure(error))
                            return
                        }

                        guard let result = result, result.isFinal else {
                            return
                        }

                        let text = result.bestTranscription.formattedString
                        try? FileManager.default.removeItem(at: audioURL)
                        completion(.success(text))
                    }
                }
            }
        }
    }

    private func exportAudioTrack(from videoURL: URL, completion: @escaping (Result<URL, Error>) -> Void) {
        let asset = AVAsset(url: videoURL)
        if asset.tracks(withMediaType: .audio).isEmpty {
            completion(.failure(NSError(
                domain: "VideoProcessor",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "视频没有可识别的音轨"]
            )))
            return
        }

        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            completion(.failure(NSError(
                domain: "VideoProcessor",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "无法创建音频导出会话"]
            )))
            return
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")

        try? FileManager.default.removeItem(at: outputURL)

        exporter.outputURL = outputURL
        exporter.outputFileType = .m4a
        exporter.shouldOptimizeForNetworkUse = true

        exporter.exportAsynchronously {
            switch exporter.status {
            case .completed:
                completion(.success(outputURL))
            case .failed:
                completion(.failure(exporter.error ?? NSError(
                    domain: "VideoProcessor",
                    code: 5,
                    userInfo: [NSLocalizedDescriptionKey: "音轨导出失败"]
                )))
            case .cancelled:
                completion(.failure(NSError(
                    domain: "VideoProcessor",
                    code: 6,
                    userInfo: [NSLocalizedDescriptionKey: "音轨导出已取消"]
                )))
            default:
                completion(.failure(NSError(
                    domain: "VideoProcessor",
                    code: 7,
                    userInfo: [NSLocalizedDescriptionKey: "音轨导出未完成"]
                )))
            }
        }
    }

    private func requestSpeechAuthorization(_ completion: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            completion(status == .authorized)
        }
    }

    // MARK: - Helpers

    private func uniquePreservingOrder(_ input: [String]) -> [String] {
        var seen = Set<String>()
        var output: [String] = []
        for item in input where !item.isEmpty {
            if seen.insert(item).inserted {
                output.append(item)
            }
        }
        return output
    }

    private func finishSuccess(_ text: String, completion: ((String) -> Void)?) {
        DispatchQueue.main.async {
            self.processedText = text
            self.errorMessage = nil
            self.isProcessing = false
            completion?(text)
        }
    }

    private func finishFailure(_ message: String) {
        DispatchQueue.main.async {
            self.errorMessage = message
            self.isProcessing = false
        }
    }
}
