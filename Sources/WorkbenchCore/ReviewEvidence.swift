import Foundation

public enum ReviewEvidence {
    public static func text(artifacts: [WorkArtifact], archive: RunArchive, maximumBytes: Int = 100000) throws -> String {
        var remaining = max(0, maximumBytes), sections: [String] = []
        let textTypes = Set(["txt", "md", "json", "csv", "log", "swift", "py", "html", "css", "js", "ts", "xml", "yaml", "yml", "diff", "patch"])
        for artifact in artifacts {
            let url = try archive.url(for: artifact)
            let header = "文件：\(url.lastPathComponent)；run：\(artifact.runID)；大小：\(artifact.byteCount)字节；\(artifact.accepted ? "已验收的前序交付" : "当前候选")"
            guard textTypes.contains(artifact.fileType), remaining > 0 else {
                sections.append(header + "\n未提供可读正文。若验收需要检查此内容，应返回blocked并请求人工检查。")
                continue
            }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let limit = min(20000, remaining)
            let data = try handle.read(upToCount: limit) ?? Data()
            remaining -= data.count
            var decoder = UTF8StreamDecoder()
            let body = decoder.append(data)
            let truncated = artifact.byteCount > data.count
            sections.append(header + "\n<artifact_data>\n" + body + "\n</artifact_data>" + (truncated ? "\n正文超出限额，已截断。不能据此确认全文达标，应返回blocked。" : ""))
        }
        return sections.joined(separator: "\n\n")
    }
}
