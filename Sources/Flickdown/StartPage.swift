import AppKit
import SwiftUI

struct StartPage: View {
    var recentURLs: [URL]
    let newDocument: () -> Void
    let openDocument: () -> Void
    let openRecent: (URL) -> Void

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 88, height: 88)
                    .accessibilityHidden(true)
                Text("Flickdown")
                    .font(.system(size: 30, weight: .bold))
                    .padding(.top, 4)
                VStack(spacing: 10) {
                    Button(action: openDocument) {
                        Label(L("打开文件…", "Open File…"), systemImage: "folder")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    Button(action: newDocument) {
                        Label(L("新建 Markdown", "New Markdown"), systemImage: "square.and.pencil")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .controlSize(.large)
                .padding(.top, 28)
            }
            .padding(.horizontal, 30)
            .frame(width: 248)
            .frame(maxHeight: .infinity)

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                Text(L("最近打开", "Recent Files"))
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                if recentURLs.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "clock")
                            .font(.title)
                            .accessibilityHidden(true)
                        Text(L("尚无最近打开的文件", "No recent files"))
                    }
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(recentURLs, id: \.self) { url in
                                Button { openRecent(url) } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: "doc.text")
                                            .foregroundStyle(.secondary)
                                            .accessibilityHidden(true)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(url.lastPathComponent)
                                                .fontWeight(.medium)
                                            Text((url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    }
                                    .padding(.vertical, 6)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help(url.path)
                            }
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(.background)
        }
    }
}
