import SwiftUI

struct ContentView: View {
    @State private var playlistURL = ""
    @State private var channels: [Channel] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var searchText = ""

    var filtered: [Channel] {
        if searchText.isEmpty { return channels }
        return channels.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Ô nhập playlist
                HStack {
                    TextField("Dán link playlist .m3u", text: $playlistURL)
                        .textFieldStyle(.roundedBorder)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    Button("Tải") { Task { await loadPlaylist() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(isLoading || playlistURL.isEmpty)
                }
                .padding()

                if isLoading {
                    ProgressView("Đang tải playlist...")
                        .padding()
                }

                if let err = errorMessage {
                    Text(err)
                        .foregroundColor(.red)
                        .font(.footnote)
                        .padding(.horizontal)
                }

                // Danh sách kênh
                List(filtered) { ch in
                    NavigationLink(destination: PlayerView(channel: ch)) {
                        HStack {
                            AsyncImage(url: URL(string: ch.logo ?? "")) { img in
                                img.resizable().scaledToFit()
                            } placeholder: {
                                Color.gray.opacity(0.2)
                            }
                            .frame(width: 56, height: 32)
                            .cornerRadius(4)

                            Text(ch.name)
                                .lineLimit(1)

                            Spacer()

                            if ch.hasDRM {
                                Text("DRM")
                                    .font(.caption2).bold()
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Color.orange.opacity(0.25))
                                    .cornerRadius(4)
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .searchable(text: $searchText, prompt: "Tìm kênh")
            }
            .navigationTitle("MonPlayer DRM")
        }
        .navigationViewStyle(.stack)
    }

    func loadPlaylist() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            channels = try await M3UParser.load(from: playlistURL)
            if channels.isEmpty {
                errorMessage = "Playlist không có kênh nào"
            }
        } catch {
            errorMessage = "Lỗi tải playlist: \(error.localizedDescription)"
        }
    }
}
