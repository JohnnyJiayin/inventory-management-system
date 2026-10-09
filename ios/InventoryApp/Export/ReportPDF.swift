import UIKit

/// PDF 导出（Issue #52）：用 UIGraphicsPDFRenderer 生成 A4 横向页面，包含标题、筛选条件和表格。
///   每行固定一行高，表格过长时在行与行之间分页（不截断行），新的一页重复表头；页脚显示页码。
///   文字用系统字体绘制，中文自动使用苹方。
enum ReportPDF {
    private static let page = CGRect(x: 0, y: 0, width: 842, height: 595) // A4 横向（点）
    private static let margin: CGFloat = 36
    private static let rowHeight: CGFloat = 18
    private static let cellPadding: CGFloat = 6
    private static let footerHeight: CGFloat = 24

    private static let titleFont = UIFont.boldSystemFont(ofSize: 18)
    private static let infoFont = UIFont.systemFont(ofSize: 10)
    private static let tableTitleFont = UIFont.boldSystemFont(ofSize: 13)
    private static let cellFont = UIFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .regular)
    private static let boldCellFont = UIFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .semibold)

    static func render(_ doc: ReportDocument) -> Data {
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [kCGPDFContextTitle as String: doc.title, kCGPDFContextCreator as String: "库存管理系统"]
        let renderer = UIGraphicsPDFRenderer(bounds: page, format: format)
        return renderer.pdfData { ctx in
            var state = PageState(ctx: ctx)
            state.newPage()

            draw(doc.title, font: titleFont, in: &state)
            draw(doc.filterText, font: infoFont, color: .darkGray, in: &state)
            draw(ReportExporter.generatedText(doc.generatedAt), font: infoFont, color: .darkGray, in: &state)
            state.y += 8

            for table in doc.tables {
                drawTable(table, in: &state)
                state.y += 14
            }
            if let note = doc.note {
                draw(note, font: infoFont, color: .darkGray, in: &state)
            }
            state.finishPage()
        }
    }

    private struct PageState {
        let ctx: UIGraphicsPDFRendererContext
        var y: CGFloat = 0
        var pageNumber = 0

        var bottom: CGFloat { page.height - margin - footerHeight }

        mutating func newPage() {
            if pageNumber > 0 { finishPage() }
            ctx.beginPage()
            pageNumber += 1
            y = margin
        }

        /// 页脚页码
        func finishPage() {
            let text = "第 \(pageNumber) 页" as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: infoFont, .foregroundColor: UIColor.gray]
            let size = text.size(withAttributes: attrs)
            text.draw(at: CGPoint(x: page.width - margin - size.width, y: page.height - margin - size.height),
                      withAttributes: attrs)
        }

        /// 剩余高度不够时换页
        mutating func ensure(_ height: CGFloat) {
            if y + height > bottom { newPage() }
        }
    }

    /// 多行文字（自动换行）
    private static func draw(_ text: String, font: UIFont, color: UIColor = .black, in state: inout PageState) {
        let width = page.width - margin * 2
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let rect = (text as NSString).boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                                   options: [.usesLineFragmentOrigin], attributes: attrs, context: nil)
        state.ensure(rect.height)
        (text as NSString).draw(with: CGRect(x: margin, y: state.y, width: width, height: rect.height),
                                options: [.usesLineFragmentOrigin], attributes: attrs, context: nil)
        state.y += ceil(rect.height) + 4
    }

    private static func drawTable(_ table: ReportTable, in state: inout PageState) {
        let widths = columnWidths(table)
        // 表格标题 + 表头 + 至少一行放在同一页
        state.ensure(tableTitleFont.lineHeight + 6 + rowHeight * 2)
        let titleAttrs: [NSAttributedString.Key: Any] = [.font: tableTitleFont]
        (table.title as NSString).draw(at: CGPoint(x: margin, y: state.y), withAttributes: titleAttrs)
        state.y += tableTitleFont.lineHeight + 6

        drawHeader(table, widths: widths, in: &state)
        if table.rows.isEmpty {
            drawRow([.text("没有符合条件的数据")], columns: [ReportColumn(title: "")],
                    widths: [widths.reduce(0, +)], bold: false, shaded: false, in: &state)
        }
        for (i, values) in table.rows.enumerated() {
            if state.y + rowHeight > state.bottom {
                state.newPage()
                drawHeader(table, widths: widths, in: &state)
            }
            drawRow(values, columns: table.columns, widths: widths, bold: false, shaded: i % 2 == 1, in: &state)
        }
        if let total = table.total {
            if state.y + rowHeight > state.bottom {
                state.newPage()
                drawHeader(table, widths: widths, in: &state)
            }
            let line = UIBezierPath()
            line.move(to: CGPoint(x: margin, y: state.y))
            line.addLine(to: CGPoint(x: margin + widths.reduce(0, +), y: state.y))
            UIColor.black.setStroke()
            line.lineWidth = 0.8
            line.stroke()
            drawRow(total, columns: table.columns, widths: widths, bold: true, shaded: false, in: &state)
        }
    }

    private static func drawHeader(_ table: ReportTable, widths: [CGFloat], in state: inout PageState) {
        UIColor(white: 0.9, alpha: 1).setFill()
        UIRectFill(CGRect(x: margin, y: state.y, width: widths.reduce(0, +), height: rowHeight))
        drawRow(table.columns.map { .text($0.title) }, columns: table.columns, widths: widths,
                bold: true, shaded: false, in: &state)
    }

    private static func drawRow(_ values: [ReportValue], columns: [ReportColumn], widths: [CGFloat],
                                bold: Bool, shaded: Bool, in state: inout PageState) {
        if shaded {
            UIColor(white: 0.97, alpha: 1).setFill()
            UIRectFill(CGRect(x: margin, y: state.y, width: widths.reduce(0, +), height: rowHeight))
        }
        var x = margin
        for (i, width) in widths.enumerated() {
            let value = values.indices.contains(i) ? values[i] : .none
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            paragraph.alignment = columns.indices.contains(i) && columns[i].numeric ? .right : .left
            let font = bold ? boldCellFont : cellFont
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: paragraph]
            let rect = CGRect(x: x + cellPadding, y: state.y + (rowHeight - font.lineHeight) / 2,
                              width: width - cellPadding * 2, height: font.lineHeight)
            (value.display as NSString).draw(in: rect, withAttributes: attrs)
            x += width
        }
        state.y += rowHeight
    }

    /// 按表头和内容的最大宽度分配列宽（每列最多 220 点）；总宽超出页面时按比例缩小
    private static func columnWidths(_ table: ReportTable) -> [CGFloat] {
        let available = page.width - margin * 2
        var widths = table.columns.indices.map { i -> CGFloat in
            let texts = [table.columns[i].title] + (table.rows + [table.total ?? []])
                .compactMap { $0.indices.contains(i) ? $0[i].display : nil }
            let widest = texts.map { ($0 as NSString).size(withAttributes: [.font: boldCellFont]).width }.max() ?? 40
            return min(ceil(widest) + cellPadding * 2, 220)
        }
        let total = widths.reduce(0, +)
        if total > available {
            widths = widths.map { $0 * available / total }
        }
        return widths
    }
}
