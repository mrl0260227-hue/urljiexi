import SwiftUI
import AVKit

struct ContentView: View {
    @StateObject private var downloader = VideoDownloader()
    @StateObject private var processor = VideoProcessor()
    
    @State private var inputURL: String = ""
    @State private var downloadedVideos: [VideoItem] = []
    @State private var selectedVideo: VideoItem?
    @State private var showingTextResult = false
    
    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                // 输入区域
                VStack(alignment: .leading) {
                    Text("输入抖音链接")
                        .font(.headline)
                    
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
                
                // 列表区域
                List {
                    Section(header: Text("已下载视频")) {
                        if downloadedVideos.isEmpty {
                            Text("暂无下载内容")
                                .foregroundColor(.gray)
                        } else {
                            ForEach(downloadedVideos) { item in
                                VideoRow(item: item) {
                                    processVideo(item)
                                }
                            }
                            .onDelete(perform: deleteVideo)
                        }
                    }
                }
            }
            .navigationTitle("抖音下载与提取")
            .sheet(isPresented: $showingTextResult) {
                TextResultView(text: processor.processedText, isProcessing: processor.isProcessing)
            }
            .onAppear(perform: loadSavedVideos)
        }
    }
    
    private func downloadAction() {
        downloader.downloadVideo(from: inputURL) { url in
            if let url = url {
                let newItem = VideoItem(localURL: url, downloadDate: Date())
                DispatchQueue.main.async {
                    downloadedVideos.insert(newItem, at: 0)
                    saveVideos()
                    inputURL = ""
                }
            }
        }
    }
    
    private func processVideo(_ item: VideoItem) {
        selectedVideo = item
        showingTextResult = true
        // 默认执行语音转文字
        processor.extractTextFromAudio(videoURL: item.localURL)
    }
    
    private func deleteVideo(at offsets: IndexSet) {
        for index in offsets {
            let item = downloadedVideos[index]
            try? FileManager.default.removeItem(at: item.localURL)
        }
        downloadedVideos.remove(at: offsets)
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
            // 过滤掉本地文件已删除的项
            downloadedVideos = items.filter { FileManager.default.fileExists(atPath: $0.localURL.path) }
        }
    }
}

struct VideoRow: View {
    let item: VideoItem
    let onProcess: () -> Void
    
    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(item.fileName)
                    .font(.subheadline)
                    .lineLimit(1)
                Text(item.downloadDate, style: .date)
                    .font(.caption2)
                    .foregroundColor(.gray)
            }
            
            Spacer()
            
            Button(action: onProcess) {
                Label("提取文字", systemImage: "doc.text.magnifyingglass")
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
    @Environment(\.presentationMode) var presentationMode
    
    var body: some View {
        NavigationView {
            VStack {
                if isProcessing {
                    VStack {
                        ProgressView()
                        Text("正在提取视频中的文字...")
                            .padding()
                    }
                } else {
                    ScrollView {
                        Text(text.isEmpty ? "未能识别到文字" : text)
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

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
