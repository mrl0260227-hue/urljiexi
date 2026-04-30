import Foundation

final class VideoDownloader: ObservableObject {
    @Published var isDownloading = false
    @Published var downloadProgress: Double = 0
    @Published var errorMessage: String?

    private let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148"

    func downloadVideo(from input: String, completion: @escaping (URL?) -> Void) {
        guard let rawURL = extractURL(from: input),
              let shareURL = normalizeShareURL(rawURL) else {
            setError("无效的 URL")
            completion(nil)
            return
        }

        DispatchQueue.main.async {
            self.isDownloading = true
            self.errorMessage = nil
        }

        resolveRedirect(shareURL) { finalURL in
            guard let finalURL = finalURL else {
                self.setError("无法解析链接")
                completion(nil)
                return
            }

            self.resolveVideoId(from: finalURL) { videoId in
                guard let videoId = videoId else {
                    self.setError("找不到视频 ID")
                    completion(nil)
                    return
                }

                self.fetchVideoDataURL(videoId: videoId, fallbackURL: finalURL) { playURL in
                    guard let playURL = playURL else {
                        self.setError("获取视频地址失败")
                        completion(nil)
                        return
                    }

                    self.startDownload(from: playURL, completion: completion)
                }
            }
        }
    }

    // MARK: - URL / ID

    private func extractURL(from text: String) -> URL? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(location: 0, length: text.utf16.count)
        return detector?.firstMatch(in: text, options: [], range: range)?.url
    }

    // 兼容短链后拼接尾巴文本
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

    private func resolveVideoId(from url: URL, completion: @escaping (String?) -> Void) {
        let text = url.absoluteString
        if let id = extractVideoId(from: text) {
            completion(id)
            return
        }

        fetchHTML(from: url, referer: nil) { html in
            guard let html = html else {
                completion(nil)
                return
            }
            completion(self.extractVideoId(from: html))
        }
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

    // MARK: - Fetch playable URL

    private func fetchVideoDataURL(videoId: String, fallbackURL: URL, completion: @escaping (URL?) -> Void) {
        fetchFromLegacyAPI(videoId: videoId) { legacyURL in
            if let legacyURL = legacyURL {
                completion(legacyURL)
                return
            }

            self.fetchFromIESSharePage(videoId: videoId) { iesURL in
                if let iesURL = iesURL {
                    completion(iesURL)
                    return
                }

                self.fetchFromVideoPage(videoId: videoId) { pageURL in
                    if let pageURL = pageURL {
                        completion(pageURL)
                        return
                    }

                    // 最后兜底：直接解析跳转后的链接页面
                    self.fetchFromDirectURL(fallbackURL, completion: completion)
                }
            }
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
        request.setValue("https://www.douyin.com/", forHTTPHeaderField: "Referer")
        request.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")

        URLSession.shared.dataTask(with: request) { data, _, _ in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) else {
                completion(nil)
                return
            }

            if let play = Self.findFirstPlayableURL(in: json) {
                completion(URL(string: self.normalizePlayableURLString(play)))
                return
            }

            completion(nil)
        }.resume()
    }

    private func fetchFromIESSharePage(videoId: String, completion: @escaping (URL?) -> Void) {
        guard let pageURL = URL(string: "https://www.iesdouyin.com/share/video/\(videoId)/") else {
            completion(nil)
            return
        }

        fetchFromDirectURL(pageURL, completion: completion)
    }

    private func fetchFromVideoPage(videoId: String, completion: @escaping (URL?) -> Void) {
        guard let pageURL = URL(string: "https://www.douyin.com/video/\(videoId)") else {
            completion(nil)
            return
        }

        fetchFromDirectURL(pageURL, completion: completion)
    }

    private func fetchFromDirectURL(_ pageURL: URL, completion: @escaping (URL?) -> Void) {
        fetchHTML(from: pageURL, referer: "https://www.douyin.com/") { html in
            guard let html = html else {
                completion(nil)
                return
            }

            // 1) RENDER_DATA
            if let encoded = Self.extractScriptContent(html: html, scriptId: "RENDER_DATA"),
               let decoded = encoded.removingPercentEncoding,
               let data = decoded.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data),
               let play = Self.findFirstPlayableURL(in: obj) {
                completion(URL(string: self.normalizePlayableURLString(play)))
                return
            }

            // 2) SIGI_STATE
            if let sigi = Self.extractScriptContent(html: html, scriptId: "SIGI_STATE"),
               let data = sigi.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data),
               let play = Self.findFirstPlayableURL(in: obj) {
                completion(URL(string: self.normalizePlayableURLString(play)))
                return
            }

            // 3) 正则兜底
            if let raw = Self.extractPlayableURLFromHTML(html) {
                completion(URL(string: self.normalizePlayableURLString(raw)))
                return
            }

            completion(nil)
        }
    }

    private func fetchHTML(from url: URL, referer: String?, completion: @escaping (String?) -> Void) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
        if let referer = referer {
            request.setValue(referer, forHTTPHeaderField: "Referer")
        }

        URLSession.shared.dataTask(with: request) { data, _, _ in
            guard let data = data else {
                completion(nil)
                return
            }

            if let utf8 = String(data: data, encoding: .utf8) {
                completion(utf8)
                return
            }

            if let unicode = String(data: data, encoding: .unicode) {
                completion(unicode)
                return
            }

            completion(nil)
        }.resume()
    }

    // MARK: - Parsing helpers

    private static func extractScriptContent(html: String, scriptId: String) -> String? {
        let pattern = #"<script[^>]*id=\""# + scriptId + #"\"[^>]*>([\s\S]*?)</script>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: html, range: NSRange(location: 0, length: html.utf16.count)),
              let range = Range(match.range(at: 1), in: html) else {
            return nil
        }
        return String(html[range])
    }

    private static func findFirstPlayableURL(in object: Any) -> String? {
        if let dict = object as? [String: Any] {
            if let list = dict["url_list"] as? [String], let first = list.first,
               first.contains("play") || first.contains("video") {
                return first
            }

            if let list = dict["urlList"] as? [String], let first = list.first,
               first.contains("play") || first.contains("video") {
                return first
            }

            if let playAddr = dict["playAddr"] as? String, playAddr.contains("play") {
                return playAddr
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
        let candidates = [html, html.removingPercentEncoding ?? html]

        let patterns = [
            #"playAddr"\s*:\s*"([^"]*playwm[^"]*)""#,
            #"playAddr"\s*:\s*"([^"]*play[^"]*)""#,
            #""url_list"\s*:\s*\[\s*"([^"]+)"\s*\]"#,
            #"https:\\/\\/[^"\\]*playwm[^"\\]*"#,
            #"https:\\/\\/[^"\\]*play[^"\\]*"#,
            #"https://[^"'\\s]*playwm[^"'\\s]*"#,
            #"https://[^"'\\s]*play[^"'\\s]*"#,
            #"//[^"'\\s]*aweme[^"'\\s]*playwm[^"'\\s]*"#,
            #"//[^"'\\s]*aweme[^"'\\s]*play[^"'\\s]*"#
        ]

        for text in candidates {
            for pattern in patterns {
                guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                      let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: text.utf16.count)) else {
                    continue
                }

                let captureRange = match.numberOfRanges > 1 ? match.range(at: 1) : match.range(at: 0)
                if let range = Range(captureRange, in: text) {
                    let value = String(text[range])
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

        if s.hasPrefix("//") {
            s = "https:" + s
        }

        if let decoded = s.removingPercentEncoding {
            s = decoded
        }

        return s
    }

    private func normalizePlayableURLString(_ url: String) -> String {
        var s = url
        s = s.replacingOccurrences(of: "playwm", with: "play")
        s = s.replacingOccurrences(of: "\\u0026", with: "&")
        s = s.replacingOccurrences(of: "&amp;", with: "&")
        if s.hasPrefix("//") {
            s = "https:" + s
        }
        return s
    }

    // MARK: - Download

    private func startDownload(from url: URL, completion: @escaping (URL?) -> Void) {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.douyin.com/", forHTTPHeaderField: "Referer")

        URLSession.shared.downloadTask(with: request) { localURL, _, error in
            guard let localURL = localURL, error == nil else {
                self.setError("下载失败: \(error?.localizedDescription ?? "未知错误")")
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
                self.setError("文件保存失败")
                completion(nil)
            }
        }.resume()
    }

    // MARK: - UI state

    private func setError(_ message: String) {
        DispatchQueue.main.async {
            self.errorMessage = message
            self.isDownloading = false
        }
    }
}
