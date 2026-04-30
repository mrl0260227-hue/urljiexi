import Foundation

class VideoDownloader: ObservableObject {
    @Published var isDownloading = false
    @Published var downloadProgress: Double = 0
    @Published var errorMessage: String?

    func downloadVideo(from urlString: String, completion: @escaping (URL?) -> Void) {
        guard let url = extractURL(from: urlString) else {
            self.errorMessage = "无效的 URL"
            completion(nil)
            return
        }

        self.isDownloading = true
        self.errorMessage = nil
        
        // 1. 获取重定向后的长链接
        resolveRedirect(url) { longURL in
            guard let longURL = longURL else {
                DispatchQueue.main.async {
                    self.errorMessage = "无法解析链接"
                    self.isDownloading = false
                }
                completion(nil)
                return
            }
            
            // 2. 提取视频 ID
            guard let videoId = self.extractVideoId(from: longURL.absoluteString) else {
                DispatchQueue.main.async {
                    self.errorMessage = "找不到视频 ID"
                    self.isDownloading = false
                }
                completion(nil)
                return
            }
            
            // 3. 调用抖音 API 获取视频信息 (这是一个示例 API 接口，实际可能需要更复杂的解析)
            self.fetchVideoInfo(videoId: videoId) { videoDataURL in
                guard let videoDataURL = videoDataURL else {
                    DispatchQueue.main.async {
                        self.errorMessage = "获取视频地址失败"
                        self.isDownloading = false
                    }
                    completion(nil)
                    return
                }
                
                // 4. 下载视频
                self.startDownload(from: videoDataURL, completion: completion)
            }
        }
    }
    
    private func extractURL(from text: String) -> URL? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let matches = detector?.matches(in: text, options: [], range: NSRange(location: 0, length: text.utf16.count))
        return matches?.first?.url
    }
    
    private func resolveRedirect(_ url: URL, completion: @escaping (URL?) -> Void) {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        
        let task = URLSession.shared.dataTask(with: request) { _, response, _ in
            completion(response?.url)
        }
        task.resume()
    }
    
    private func extractVideoId(from urlString: String) -> String? {
        // 匹配 /video/(\d+)
        let pattern = "/video/(\\d+)"
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: urlString, range: NSRange(location: 0, length: urlString.utf16.count)) {
            if let range = Range(match.range(at: 1), in: urlString) {
                return String(urlString[range])
            }
        }
        return nil
    }
    
    private func fetchVideoInfo(videoId: String, completion: @escaping (URL?) -> Void) {
        let apiURLString = "https://www.iesdouyin.com/web/api/v2/aweme/iteminfo/?item_ids=\(videoId)"
        guard let url = URL(string: apiURLString) else {
            completion(nil)
            return
        }
        
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 13_2_3 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/13.0.3 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        
        URLSession.shared.dataTask(with: request) { data, _, _ in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let itemList = json["item_list"] as? [[String: Any]],
                  let item = itemList.first,
                  let video = item["video"] as? [String: Any],
                  let playAddr = video["play_addr"] as? [String: Any],
                  let urlList = playAddr["url_list"] as? [String],
                  let firstURL = urlList.first else {
                completion(nil)
                return
            }
            
            // 抖音无水印链接通常是将 playwm 替换为 play
            let noWatermarkURLString = firstURL.replacingOccurrences(of: "playwm", with: "play")
            completion(URL(string: noWatermarkURLString))
        }.resume()
    }
    
    private func startDownload(from url: URL, completion: @escaping (URL?) -> Void) {
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 13_2_3 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/13.0.3 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        
        let task = URLSession.shared.downloadTask(with: request) { localURL, response, error in
            guard let localURL = localURL, error == nil else {
                DispatchQueue.main.async {
                    self.errorMessage = "下载失败: \(error?.localizedDescription ?? "未知错误")"
                    self.isDownloading = false
                }
                completion(nil)
                return
            }
            
            // 保存到文档目录
            let fileManager = FileManager.default
            let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let destinationURL = documentsURL.appendingPathComponent("\(UUID().uuidString).mp4")
            
            try? fileManager.moveItem(at: localURL, to: destinationURL)
            
            DispatchQueue.main.async {
                self.isDownloading = false
                completion(destinationURL)
            }
        }
        task.resume()
    }
}
