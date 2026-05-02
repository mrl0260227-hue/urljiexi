import SwiftUI
import AVKit

struct ContentView: View {
    @StateObject private var downloader = VideoDownloader()
    @StateObject private var processor = VideoProcessor()

    @State private var inputURL: String = ""
    @State private var downloadedVideos: [VideoItem] = []
    @State private var showingTextResult = false
    @State private var showingPlayer = false
    @State private var playingVideoURL: URL?

    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                VStack(alignment: .leading) {
                    HStack {
                        Text("输入抖音链接")
                            .font(.headline)
                        Spacer()
                        Button(action: {
                            if let string = UIPasteboard.general.string {
                                inputURL = string
                            }
                        }) {
                            Label("粘贴", systemImage: "doc.on.clipboard")
                                .font(.caption)
                        }
                    }

                    TextField("在此粘贴抖音分享链接...", text: $inputURL)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .padding(.vertical, 5)

                    Button(action: downloadAction) {
                        HStack {
                            if downloader.isDownloading {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            } else {
                                Image(systemName: "icloud.and.arrow.down")
                            }
                            Text(downloader.isDownloading ? "正在下载..." : "开始下载")
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                    }
                    .disabled(inputURL.isEmpty || downloader.isDownloading)
                }
                .padding()
                .background(Color(.systemGray6))
                .cornerRadius(12)
                .padding(.horizontal)

                if let error = downloader.errorMessage {
                    Text(error)
                        .foregroundColor(.red)
                        .font(.caption)
                }

                List {
                    Section(header: Text("已下载视频")) {
                        if downloadedVideos.isEmpty {
                            Text("暂无下载内容")
                                .foregroundColor(.gray)
                        } else {
                            ForEach(downloadedVideos) { item in
                                VideoRow(
                                    item: item,
                                    onPlay: { playVideo(item) },
                                    onProcess: { processVideo(item) }
                                )
                            }
                            .onDelete(perform: deleteVideo)
                        }
                    }
                }
            }
            .navigationTitle("抖音下载与提取")
            .sheet(isPresented: $showingTextResult) {
                TextResultView(
                    text: processor.processedText,
                    isProcessing: processor.isProcessing,
                    errorMessage: processor.errorMessage
                )
            }
            .sheet(isPresented: $showingPlayer) {
                if let videoURL = playingVideoURL {
                    VideoPlayerSheet(videoURL: videoURL)
                }
            }
            .onAppear(perform: loadSavedVideos)
        }
    }

    private func downloadAction() {
        downloader.downloadVideo(from: inputURL) { fileNameURL in
            if let fileName = fileNameURL?.absoluteString {
                let newItem = VideoItem(relativePath: fileName, downloadDate: Date())
                DispatchQueue.main.async {
                    downloadedVideos.insert(newItem, at: 0)
                    saveVideos()
                    inputURL = ""
                }
            }
        }
    }

    private func playVideo(_ item: VideoItem) {
        guard FileManager.default.fileExists(atPath: item.localURL.path) else { return }
        playingVideoURL = item.localURL
        showingPlayer = true
    }

    private func processVideo(_ item: VideoItem) {
        showingTextResult = true
        processor.extractSubtitleText(videoURL: item.localURL)
    }

    private func deleteVideo(at offsets: IndexSet) {
        for index in offsets {
            let item = downloadedVideos[index]
            try? FileManager.default.removeItem(at: item.localURL)
        }
        downloadedVideos.remove(atOffsets: offsets)
        saveVideos()
    }

    private func saveVideos() {
        if let data = try? JSONEncoder().encode(downloadedVideos) {
            UserDefaults.standard.set(data, forKey: "saved_videos")
        }
    }

    private func loadSavedVideos() {
        if let data = UserDefaults.standard.data(forKey: "saved_videos"),
           let items = try? JSONDecoder().decode([VideoItem].self, from: data) {
            downloadedVideos = items.filter { FileManager.default.fileExists(atPath: $0.localURL.path) }
        }
    }
}

struct VideoRow: View {
    let item: VideoItem
    let onPlay: () -> Void
    let onProcess: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading) {
                Text(item.fileName)
                    .font(.subheadline)
                    .lineLimit(1)
                Text(item.downloadDate, style: .date)
                    .font(.caption2)
                    .foregroundColor(.gray)
            }

            Spacer()

            Button(action: onPlay) {
                Label("播放", systemImage: "play.circle")
                    .font(.caption)
            }
            .buttonStyle(BorderlessButtonStyle())
            .padding(8)
            .background(Color.blue.opacity(0.1))
            .cornerRadius(8)

            Button(action: onProcess) {
                Label("提取字幕", systemImage: "doc.text.magnifyingglass")
                    .font(.caption)
            }
            .buttonStyle(BorderlessButtonStyle())
            .padding(8)
            .background(Color.green.opacity(0.1))
            .cornerRadius(8)
        }
        .padding(.vertical, 4)
    }
}

struct TextResultView: View {
    let text: String
    let isProcessing: Bool
    let errorMessage: String?
    @Environment(\.presentationMode) var presentationMode

    var body: some View {
        NavigationView {
            VStack {
                if isProcessing {
                    VStack {
                        ProgressView()
                        Text("正在提取视频中的中英文字幕...")
                            .padding()
                    }
                } else if let errorMessage = errorMessage, !errorMessage.isEmpty {
                    Text(errorMessage)
                        .foregroundColor(.red)
                        .padding()
                } else {
                    ScrollView {
                        Text(text.isEmpty ? "未能识别到字幕" : text)
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .navigationTitle("提取结果")
            .navigationBarItems(trailing: Button("关闭") {
                presentationMode.wrappedValue.dismiss()
            })
        }
    }
}

struct VideoPlayerSheet: View {
    let videoURL: URL
    @Environment(\.presentationMode) var presentationMode

    var body: some View {
        NavigationView {
            VideoPlayer(player: AVPlayer(url: videoURL))
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("本地播放")
                .navigationBarItems(trailing: Button("关闭") {
                    presentationMode.wrappedValue.dismiss()
                })
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}


