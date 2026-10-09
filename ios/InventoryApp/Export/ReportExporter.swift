import Foundation

/// 报表导出（Issue #50 CSV、#51 Excel、#52 PDF，需求 15.6）。
/// 三种格式都从同一份 ReportDocument 生成，内容与屏幕一致；文件写到临时目录，通过系统分享面板保存或发送。
enum ReportExporter {
    enum Format: String, CaseIterable, Identifiable {
        case excel, csv, pdf
        var id: Self { self }

        var title: String {
            switch self {
            case .excel: "Excel（.xlsx）"
            case .csv: "CSV"
            case .pdf: "PDF"
            }
        }

        var fileExtension: String {
            switch self {
            case .excel: "xlsx"
            case .csv: "csv"
            case .pdf: "pdf"
            }
        }
    }

    static func export(_ doc: ReportDocument, as format: Format) throws -> URL {
        let data: Data
        switch format {
        case .csv: data = csv(doc)
        case .excel: data = try XLSXWriter.workbook(doc)
        case .pdf: data = ReportPDF.render(doc)
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = exportStamp(doc.generatedAt)
        let url = dir.appendingPathComponent("\(doc.title)-\(stamp).\(format.fileExtension)")
        try data.write(to: url, options: .atomic)
        return url
    }

    /// 文件名中的时间，例如 20261009-1930（北京时间）
    static func exportStamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = BeijingDate.timeZone
        f.dateFormat = "yyyyMMdd-HHmm"
        return f.string(from: date)
    }

    static func generatedText(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = BeijingDate.timeZone
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return "导出时间：\(f.string(from: date))（北京时间）"
    }

    // MARK: - CSV（Issue #50）

    /// UTF-8 带 BOM（Excel 打开中文不乱码），CRLF 换行；多个表格之间空一行，每个表格前一行为表格标题
    static func csv(_ doc: ReportDocument) -> Data {
        var lines: [String] = [
            csvLine([doc.title]),
            csvLine([doc.filterText]),
            csvLine([generatedText(doc.generatedAt)]),
        ]
        for table in doc.tables {
            lines.append("")
            if doc.tables.count > 1 { lines.append(csvLine([table.title])) }
            lines.append(csvLine(table.columns.map(\.title)))
            lines += table.rows.map { csvLine($0.map(\.plain)) }
            if let total = table.total { lines.append(csvLine(total.map(\.plain))) }
        }
        if let note = doc.note {
            lines.append("")
            lines.append(csvLine([note]))
        }
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data((lines.joined(separator: "\r\n") + "\r\n").utf8))
        return data
    }

    private static func csvLine(_ fields: [String]) -> String {
        fields.map { field in
            // 含逗号、引号、换行时加引号；以 = + - @ 开头的文字前加单引号，防止被表格软件当作公式执行
            var f = field
            if let first = f.first, "=+-@".contains(first), Decimal(string: f) == nil { f = "'" + f }
            if f.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) {
                return "\"" + f.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }
            return f
        }
        .joined(separator: ",")
    }
}
