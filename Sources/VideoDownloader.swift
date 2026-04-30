import Foundation

final class VideoDownloader: ObservableObject {
    @Published var isDownloading = false
    @Published var downloadProgress: Double = 0
    @Published var errorMessage: String?

    private let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148"

    func downloadVideo(from input: String, completion: @escaping (URL?) -> Void) {
        guard let rawURL = extractURL(from: input),
              let shareURL = normalizeShareURL(rawURL) else {
            self.errorMessage = "无效的 URL"
            completion(nil)
            return
        }

        self.isDownloading = true
        self.errorMessage = nil

        resolveRedirect(shareURL) { finalURL in
            guard let finalURL = finalURL else {
                DispatchQueue.main.async {
                    self.errorMessage = "无法解析链接"
                    self.isDownloading = false
                }
                completion(nil)
                return
            }

            guard let videoId = self.extractVideoId(from: finalURL.absoluteString) else {
                DispatchQueue.main.async {
                    self.errorMessage = "找不到视频 ID"
                    self.isDownloading = false
                }
                completion(nil)
                return
            }

            self.fetchVideoDataURL(videoId: videoId) { playURL in
                guard let playURL = playURL else {
                    DispatchQueue.main.async {
                        self.errorMessage = "获取视频地址失败"
                        self.isDownloading = false
                    }
                    completion(nil)
                    return
                }

                self.startDownload(from: playURL, completion: completion)
            }
        }
    }

    private func extractURL(from text: String) -> URL? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(location: 0, length: text.utf16.count)
        return detector?.firstMatch(in: text, options: [], range: range)?.url
    }

    // 兼容“短链 + 尾巴文本”
    private func normalizeShareURL(_ url: URL) -> URL? {
        guard let host = url.host?.lowercased() else { return url }
        if host == "v.douyin.com" || host.hasSuffix(".v.douyin.com") {
            let parts = url.path.split(separator: "/").map(String.init).filter { !$0.isEmpty }
            guard let token = parts.first else { return url }
            let scheme = url.scheme ?? "https"
            return URL(string: "\(scheme)://\(host)/\(token)/")
        }
        return url
    }

    private func resolveRedirect(_ url: URL, completion: @escaping (URL?) -> Void) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { _, response, _ in
            completion(response?.url ?? url)
        }.resume()
    }

    private func extractVideoId(from text: String) -> String? {
        let patterns = [
            #"/video/(\d{10,24})"#,
            #"/share/video/(\d{10,24})"#,
            #"[?&]modal_id=(\d{10,24})"#,
            #"[?&]item_ids?=(\d{10,24})"#,
            #"\"aweme_id\"\s*:\s*\"(\d{10,24})\""#,
            #"\"itemId\"\s*:\s*\"(\d{10,24})\""#
        ]

        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
               let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: text.utf16.count)),
               let range = Range(match.range(at: 1), in: text) {
                return String(text[range])
            }
        }

        if let decoded = text.removingPercentEncoding, decoded != text {
            return extractVideoId(from: decoded)
        }
        return nil
    }

    // 先走旧接口，失败后回退网页解析（关键修复）
    private func fetchVideoDataURL(videoId: String, completion: @escaping (URL?) -> Void) {
        fetchFromLegacyAPI(videoId: videoId) { legacyURL in
            if let legacyURL = legacyURL {
                completion(legacyURL)
                return
            }

            self.fetchFromVideoPage(videoId: videoId, completion: completion)
        }
    }

    private func fetchFromLegacyAPI(videoId: String, completion: @escaping (URL?) -> Void) {
        let api = "https://www.iesdouyin.com/web/api/v2/aweme/iteminfo/?item_ids=\(videoId)"
        guard let url = URL(string: api) else {
            completion(nil)
            return
        }

        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { data, _, _ in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let itemList = json["item_list"] as? [[String: Any]],
                  let item = itemList.first else {
                completion(nil)
                return
            }

            if let play = Self.findFirstPlayableURL(in: item) {
                completion(URL(string: self.normalizePlayableURLString(play)))
                return
            }

            completion(nil)
        }.resume()
    }

    private func fetchFromVideoPage(videoId: String, completion: @escaping (URL?) -> Void) {
        guard let pageURL = URL(string: "https://www.douyin.com/video/\(videoId)") else {
            completion(nil)
            return
        }

        var request = URLRequest(url: pageURL)
        request.httpMethod = "GET"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.douyin.com/", forHTTPHeaderField: "Referer")
        request.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")

        URLSession.shared.dataTask(with: request) { data, _, _ in
            guard let data = data,
                  let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .unicode) else {
                completion(nil)
                return
            }

            if let raw = Self.extractPlayableURLFromHTML(html) {
                let normalized = self.normalizePlayableURLString(raw)
                completion(URL(string: normalized))
                return
            }

            completion(nil)
        }.resume()
    }

    private static func findFirstPlayableURL(in object: Any) -> String? {
        if let dict = object as? [String: Any] {
            if let list = dict["url_list"] as? [String], let first = list.first {
                if first.contains("play") || first.contains("video") {
                    return first
                }
            }
            if let list = dict["urlList"] as? [String], let first = list.first {
                if first.contains("play") || first.contains("video") {
                    return first
                }
            }

            for value in dict.values {
                if let found = findFirstPlayableURL(in: value) {
                    return found
                }
            }
        } else if let array = object as? [Any] {
            for item in array {
                if let found = findFirstPlayableURL(in: item) {
                    return found
                }
            }
        }
        return nil
    }

    private static func extractPlayableURLFromHTML(_ html: String) -> String? {
        let patterns = [
            #"https:\\/\\/[^"\\]*playwm[^"\\]*"#,
            #"https:\\/\\/[^"\\]*play[^"\\]*"#,
            #""url_list":\["([^"]+)"\]"#,
            #"https://[^"'\\s]*playwm[^"'\\s]*"#,
            #"https://[^"'\\s]*play[^"'\\s]*"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let nsRange = NSRange(location: 0, length: html.utf16.count)
            if let match = regex.firstMatch(in: html, range: nsRange) {
                let captureRange = match.numberOfRanges > 1 ? match.range(at: 1) : match.range(at: 0)
                if let range = Range(captureRange, in: html) {
                    let value = String(html[range])
                    return decodeEscapedURL(value)
                }
            }
        }
        return nil
    }

    private static func decodeEscapedURL(_ value: String) -> String {
        var s = value
        s = s.replacingOccurrences(of: "\\u002F", with: "/")
        s = s.replacingOccurrences(of: "\\/", with: "/")
        s = s.replacingOccurrences(of: "\\u0026", with: "&")
        s = s.replacingOccurrences(of: "&amp;", with: "&")
        s = s.replacingOccurrences(of: "\"", with: "")

        if let decoded = s.removingPercentEncoding {
            return decoded
        }
        return s
    }

    private func normalizePlayableURLString(_ url: String) -> String {
        var s = url
        s = s.replacingOccurrences(of: "playwm", with: "play")
        s = s.replacingOccurrences(of: "\\u0026", with: "&")
        s = s.replacingOccurrences(of: "&amp;", with: "&")
        return s
    }

    private func startDownload(from url: URL, completion: @escaping (URL?) -> Void) {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.douyin.com/", forHTTPHeaderField: "Referer")

        URLSession.shared.downloadTask(with: request) { localURL, _, error in
            guard let localURL = localURL, error == nil else {
                DispatchQueue.main.async {
                    self.errorMessage = "下载失败: \(error?.localizedDescription ?? "未知错误")"
                    self.isDownloading = false
                }
                completion(nil)
                return
            }

            let fileManager = FileManager.default
            let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let fileName = "\(UUID().uuidString).mp4"
            let destinationURL = documentsURL.appendingPathComponent(fileName)

            do {
                try fileManager.moveItem(at: localURL, to: destinationURL)
                DispatchQueue.main.async {
                    self.isDownloading = false
                    completion(URL(string: fileName))
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = "文件保存失败"
                    self.isDownloading = false
                }
                completion(nil)
            }
        }.resume()
    }
}
