import Foundation

/// 最小的 xlsx 写入（Issue #51）：每个表格一个工作表，金额为数字格式 #,##0.00，可以直接求和。
///   xlsx 是 zip 包中的几个 XML 文件（Office Open XML）。只需要写入单元格、列宽和三种样式，
///   自己生成比引入第三方库更简单，也没有依赖需要维护。文字用 inlineStr，不需要共享字符串表。
enum XLSXWriter {
    /// 样式编号（对应 styles.xml 中 cellXfs 的顺序）
    private enum Style: Int {
        case normal = 0, bold = 1, money = 2, boldMoney = 3, title = 4
    }

    static func workbook(_ doc: ReportDocument) throws -> Data {
        var zip = ZipWriter()
        let names = sheetNames(doc.tables.map(\.title))
        zip.add("[Content_Types].xml", contentTypes(sheetCount: names.count))
        zip.add("_rels/.rels", """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>\
            </Relationships>
            """)
        zip.add("xl/workbook.xml", """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" \
            xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>\
            \(names.enumerated().map { "<sheet name=\"\(escape($1))\" sheetId=\"\($0 + 1)\" r:id=\"rId\($0 + 1)\"/>" }.joined())\
            </sheets></workbook>
            """)
        zip.add("xl/_rels/workbook.xml.rels", """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
            \(names.indices.map { "<Relationship Id=\"rId\($0 + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet\($0 + 1).xml\"/>" }.joined())\
            <Relationship Id="rId\(names.count + 1)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>\
            </Relationships>
            """)
        zip.add("xl/styles.xml", styles)
        for (i, table) in doc.tables.enumerated() {
            zip.add("xl/worksheets/sheet\(i + 1).xml", sheet(table, doc: doc))
        }
        return zip.finish()
    }

    // MARK: 工作表

    private static func sheet(_ table: ReportTable, doc: ReportDocument) -> String {
        var rows: [String] = []
        var r = 0
        func row(_ cells: [String]) {
            r += 1
            rows.append("<row r=\"\(r)\">\(cells.joined())</row>")
        }
        func textCell(_ col: Int, _ text: String, _ style: Style = .normal) -> String {
            "<c r=\"\(ref(col, r + 1))\" t=\"inlineStr\" s=\"\(style.rawValue)\"><is><t xml:space=\"preserve\">\(escape(text))</t></is></c>"
        }
        func valueCell(_ col: Int, _ value: ReportValue, bold: Bool) -> String {
            switch value {
            case let .int(n):
                return "<c r=\"\(ref(col, r + 1))\" s=\"\((bold ? Style.bold : .normal).rawValue)\"><v>\(n)</v></c>"
            case let .money(m):
                return "<c r=\"\(ref(col, r + 1))\" s=\"\((bold ? Style.boldMoney : .money).rawValue)\"><v>\(Money.plain(m))</v></c>"
            case let .text(s):
                return textCell(col, s, bold ? .bold : .normal)
            case .none:
                return ""
            }
        }

        // 标题、筛选条件、导出时间，空一行后是表头
        row([textCell(0, doc.tables.count > 1 ? "\(doc.title) - \(table.title)" : doc.title, .title)])
        row([textCell(0, doc.filterText)])
        row([textCell(0, ReportExporter.generatedText(doc.generatedAt))])
        row([])
        row(table.columns.enumerated().map { textCell($0, $1.title, .bold) })
        for values in table.rows {
            row(values.enumerated().map { valueCell($0, $1, bold: false) })
        }
        if let total = table.total {
            row(total.enumerated().map { valueCell($0, $1, bold: true) })
        }
        if let note = doc.note {
            row([])
            row([textCell(0, note)])
        }

        // 列宽：按表头和内容的最大显示宽度估算（中文按 2 个字符宽）
        let cols = table.columns.indices.map { i -> String in
            let texts = [table.columns[i].title] + (table.rows + [table.total ?? []]).compactMap { $0.indices.contains(i) ? $0[i].display : nil }
            let width = min(max(texts.map(displayWidth).max() ?? 8, 8) + 2, 60)
            return "<col min=\"\(i + 1)\" max=\"\(i + 1)\" width=\"\(width)\" customWidth=\"1\"/>"
        }

        return """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">\
            <sheetViews><sheetView workbookViewId="0"><pane ySplit="5" topLeftCell="A6" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews>\
            <cols>\(cols.joined())</cols>\
            <sheetData>\(rows.joined())</sheetData>\
            </worksheet>
            """
    }

    /// 0 列、第 1 行 → "A1"
    private static func ref(_ col: Int, _ row: Int) -> String {
        var name = ""
        var n = col + 1
        while n > 0 {
            let rem = (n - 1) % 26
            name = String(UnicodeScalar(UInt8(65 + rem))) + name
            n = (n - 1) / 26
        }
        return "\(name)\(row)"
    }

    private static func displayWidth(_ s: String) -> Int {
        s.unicodeScalars.reduce(0) { $0 + ($1.value > 0x2E80 ? 2 : 1) }
    }

    /// 工作表名称：最长 31 个字符，不能含 []:*?/\ ，不能重复
    private static func sheetNames(_ titles: [String]) -> [String] {
        var used = Set<String>()
        return titles.enumerated().map { i, title in
            var name = String(title.filter { !"[]:*?/\\".contains($0) }.prefix(28))
            if name.isEmpty { name = "Sheet\(i + 1)" }
            var candidate = name
            var n = 2
            while used.contains(candidate) {
                candidate = "\(name)\(n)"
                n += 1
            }
            used.insert(candidate)
            return candidate
        }
    }

    private static func escape(_ s: String) -> String {
        var out = ""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            // XML 1.0 不允许的控制字符直接去掉
            case _ where scalar.value < 0x20 && scalar != "\t" && scalar != "\n" && scalar != "\r": continue
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    private static func contentTypes(sheetCount: Int) -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
        <Default Extension="xml" ContentType="application/xml"/>\
        <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>\
        <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>\
        \((1...max(sheetCount, 1)).map { "<Override PartName=\"/xl/worksheets/sheet\($0).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>" }.joined())\
        </Types>
        """
    }

    /// numFmtId 4 是内置格式 #,##0.00
    private static let styles = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">\
        <fonts count="3"><font><sz val="11"/><name val="Calibri"/></font>\
        <font><b/><sz val="11"/><name val="Calibri"/></font>\
        <font><b/><sz val="14"/><name val="Calibri"/></font></fonts>\
        <fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>\
        <borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>\
        <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>\
        <cellXfs count="5">\
        <xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>\
        <xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/>\
        <xf numFmtId="4" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>\
        <xf numFmtId="4" fontId="1" fillId="0" borderId="0" xfId="0" applyNumberFormat="1" applyFont="1"/>\
        <xf numFmtId="0" fontId="2" fillId="0" borderId="0" xfId="0" applyFont="1"/>\
        </cellXfs>\
        <cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>\
        </styleSheet>
        """
}

/// 只存储不压缩的 zip（xlsx 容器）。文件很小，不压缩也没问题。
struct ZipWriter {
    private var body = Data()
    private var central = Data()
    private var count: UInt16 = 0

    mutating func add(_ path: String, _ text: String) {
        add(path, Data(text.utf8))
    }

    mutating func add(_ path: String, _ data: Data) {
        let name = Data(path.utf8)
        let crc = CRC32.checksum(data)
        let offset = UInt32(body.count)
        // 固定的修改时间 1980-01-01，生成结果不随时间变化
        let time: UInt16 = 0, date: UInt16 = (0 << 9) | (1 << 5) | 1

        var local = Data()
        local.append(le32(0x0403_4B50))
        local.append(le16(20)); local.append(le16(0x0800)) // 版本；标志位 11：文件名为 UTF-8
        local.append(le16(0)) // 不压缩
        local.append(le16(time)); local.append(le16(date))
        local.append(le32(crc)); local.append(le32(UInt32(data.count))); local.append(le32(UInt32(data.count)))
        local.append(le16(UInt16(name.count))); local.append(le16(0))
        local.append(name)
        body.append(local)
        body.append(data)

        var entry = Data()
        entry.append(le32(0x0201_4B50))
        entry.append(le16(20)); entry.append(le16(20)); entry.append(le16(0x0800)); entry.append(le16(0))
        entry.append(le16(time)); entry.append(le16(date))
        entry.append(le32(crc)); entry.append(le32(UInt32(data.count))); entry.append(le32(UInt32(data.count)))
        entry.append(le16(UInt16(name.count))); entry.append(le16(0)); entry.append(le16(0))
        entry.append(le16(0)); entry.append(le16(0)); entry.append(le32(0))
        entry.append(le32(offset))
        entry.append(name)
        central.append(entry)
        count += 1
    }

    func finish() -> Data {
        var out = body
        out.append(central)
        out.append(le32(0x0605_4B50))
        out.append(le16(0)); out.append(le16(0))
        out.append(le16(count)); out.append(le16(count))
        out.append(le32(UInt32(central.count))); out.append(le32(UInt32(body.count)))
        out.append(le16(0))
        return out
    }

    private func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    private func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
}

enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}
