import Foundation
import AVFoundation
import Speech
import Vision

class VideoProcessor: ObservableObject {
    @Published var isProcessing = false
    @Published var processedText = ""
    @Published var errorMessage: String?

    // 语音转文字 (Speech-to-Text)
    func extractTextFromAudio(videoURL: URL) {
        self.isProcessing = true
        self.processedText = ""
        self.errorMessage = nil
        
        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
        
        // 检查权限
        SFSpeechRecognizer.requestAuthorization { status in
            guard status == .authorized else {
                DispatchQueue.main.async {
                    self.errorMessage = "未获得语音识别权限"
                    self.isProcessing = false
                }
                return
            }
            
            // 提取音频并识别
            self.performSpeechRecognition(url: videoURL, recognizer: recognizer)
        }
    }
    
    private func performSpeechRecognition(url: URL, recognizer: SFSpeechRecognizer?) {
        guard let recognizer = recognizer, recognizer.isAvailable else {
            DispatchQueue.main.async {
                self.errorMessage = "语音识别不可用"
                self.isProcessing = false
            }
            return
        }
        
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        
        recognizer.recognitionTask(with: request) { result, error in
            if let error = error {
                DispatchQueue.main.async {
                    self.errorMessage = "识别出错: \(error.localizedDescription)"
                    self.isProcessing = false
                }
                return
            }
            
            if let result = result {
                if result.isFinal {
                    DispatchQueue.main.async {
                        self.processedText = result.bestTranscription.formattedString
                        self.isProcessing = false
                    }
                }
            }
        }
    }

    // 视频帧文字识别 (OCR) - 示例代码，展示如何从视频中提取文字
    func extractTextFromFrames(videoURL: URL) {
        self.isProcessing = true
        self.processedText = "正在进行 OCR 文字识别..."
        
        let asset = AVAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        
        // 简单起见，提取第 1 秒、第 5 秒、第 10 秒的帧进行识别
        let times = [NSValue(time: CMTime(seconds: 1, preferredTimescale: 600)),
                     NSValue(time: CMTime(seconds: 5, preferredTimescale: 600))]
        
        var recognizedTexts: [String] = []
        let group = DispatchGroup()
        
    for time in times {
        group.enter()
        generator.generateCGImagesAsynchronously(forTimes: [time]) { _, image, _, _, _ in
            if let image = image {
                group.enter()
                self.recognizeTextInImage(image: image) { text in
                    if !text.isEmpty {
                        recognizedTexts.append(text)
                    }
                    group.leave()
                    group.leave()
                }
            } else {
                group.leave()
            }
        }
    }
        
        group.notify(queue: .main) {
            self.processedText = recognizedTexts.joined(separator: "\n---\n")
            self.isProcessing = false
        }
    }
    
    private func recognizeTextInImage(image: CGImage, completion: @escaping (String) -> Void) {
        let request = VNRecognizeTextRequest { request, error in
            guard let observations = request.results as? [VNRecognizedTextObservation] else {
                completion("")
                return
            }
            
            let text = observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
            completion(text)
        }
        
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try? handler.perform([request])
    }
}
