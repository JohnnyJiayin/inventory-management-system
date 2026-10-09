import XCTest

/// Sprint 2 端到端流程：经销商 → 价格 → 新建出库订单 → 扫码 → 单台改价 → 运费 → 确认出库 → 保修 → 撤销。
/// 依赖 supabase/seed.sql 中的演示数据：型号 DEMO-OUT（演示音箱 SPK-1）的机身号 O1–O5 在库。
/// 测试最后撤销订单，产品恢复在库，可以重复运行。
final class Sprint2FlowTests: FlowTestCase {
    func testOutboundFlow() throws {
        app.launch()
        try loginIfNeeded()
        let tag = String(Int(Date().timeIntervalSince1970))
        let company = "UI经销商\(tag)"

        // ---------------------------------------------------------------- 经销商与价格
        sidebar("经销商").tap()
        app.buttons["添加经销商"].tap()
        type(into: app.textFields["公司名称（必填）"], company)
        type(into: app.textFields["联系人（必填）"], "王五")
        type(into: app.textFields["电话号码（必填）"], "13900000000")
        type(into: app.textFields["详细地址（必填）"], "杭州市测试路 \(tag) 号")
        app.buttons["保存"].tap()
        let row = app.staticTexts[company]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "新增的经销商出现在列表中")

        // 重复公司名称被拒绝
        app.buttons["添加经销商"].tap()
        type(into: app.textFields["公司名称（必填）"], company)
        type(into: app.textFields["联系人（必填）"], "x")
        type(into: app.textFields["电话号码（必填）"], "1")
        type(into: app.textFields["详细地址（必填）"], "x")
        app.buttons["保存"].tap()
        XCTAssertTrue(app.staticTexts["公司名称「\(company)」已存在"].waitForExistence(timeout: 10))
        app.buttons["取消"].tap()

        row.tap()
        XCTAssertTrue(app.staticTexts["默认"].waitForExistence(timeout: 10), "第一个地址自动成为默认地址")
        app.buttons["设置型号价格"].tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "请选择")).firstMatch.tap()
        app.buttons["演示音箱 SPK-1"].tap()
        type(into: app.textFields["默认单价（元）"], "200")
        app.buttons["保存"].tap()
        XCTAssertTrue(app.staticTexts["演示音箱 SPK-1"].waitForExistence(timeout: 10), "价格表显示型号")

        // ---------------------------------------------------------------- 新建出库订单
        sidebar("出库订单").tap()
        app.buttons["新建出库订单"].tap()
        // 默认显示最近一次选择的经销商（上次运行留下的），先更换
        if app.buttons["更换"].waitForExistence(timeout: 3) { app.buttons["更换"].tap() }
        type(into: app.textFields["输入公司名称搜索"], tag)
        // 只点经销商候选行（背后的订单列表行也含经销商名称，但以单号开头）
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", company)).firstMatch.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS '杭州市测试路'")).firstMatch
            .waitForExistence(timeout: 5), "自动选择默认地址")
        // 键盘收起动画期间的点击可能无效；再点一次也只会生成一张订单（同一请求编号）
        let scanPage = app.navigationBars["出库扫码"]
        for _ in 0..<2 where !scanPage.exists {
            app.buttons["创建订单"].tap()
            _ = scanPage.waitForExistence(timeout: 8)
        }
        XCTAssertTrue(scanPage.exists, "创建后进入出库扫码页")
        let orderNo = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'CK'")).firstMatch.label
        XCTAssertTrue(app.staticTexts[company].exists, "扫码页顶部显示经销商")

        // ---------------------------------------------------------------- 扫码
        manualInput("DEMO-OUT")
        waitForText(containing: "已识别：演示音箱 SPK-1")
        manualInput("O1")
        waitForText(containing: "已加入：演示音箱 SPK-1 机身号 O1")
        manualInput("O1")
        waitForText(containing: "机身号 O1 已在本订单中")

        // 单台订单改价为 0（售后补发）
        app.buttons["改价"].tap()
        let priceField = app.alerts.textFields.firstMatch
        XCTAssertTrue(priceField.waitForExistence(timeout: 5))
        priceField.clearAndType("0")
        app.alerts.buttons["保存"].tap()
        waitForText(containing: "实际单价已改为")

        // 已改价后扫入第 2 台：提示恢复默认单价，确认后加入
        manualInput("O2")
        let alert = app.alerts["多台订单不能改价"]
        XCTAssertTrue(alert.waitForExistence(timeout: 10))
        alert.buttons["继续加入"].tap()
        waitForText(containing: "已加入：演示音箱 SPK-1 机身号 O2")
        XCTAssertFalse(app.buttons["改价"].exists, "多台订单没有改价入口")

        // 运费留空时不能确认
        let confirm = app.buttons["确认出库（2 台）"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        XCTAssertFalse(confirm.isEnabled, "运费留空时不能确认出库")
        type(into: app.textFields["运费"], "15")
        waitForText(containing: "415.00")  // 200 × 2 + 15

        // ---------------------------------------------------------------- 确认出库
        confirm.tap()
        waitForText(containing: "出库成功")
        XCTAssertTrue(app.staticTexts["已完成"].waitForExistence(timeout: 5))

        // ---------------------------------------------------------------- 保修查询
        sidebar("保修查询").tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        search.typeText(orderNo)
        XCTAssertTrue(app.staticTexts["O1"].waitForExistence(timeout: 10), "出库后可以查询保修")
        XCTAssertTrue(app.staticTexts["保修中"].firstMatch.exists)

        // ---------------------------------------------------------------- 经销商历史订单 → 撤销
        sidebar("经销商").tap()
        app.staticTexts[company].tap()
        let orderRow = app.staticTexts[orderNo]
        XCTAssertTrue(orderRow.waitForExistence(timeout: 10), "经销商详情显示历史订单")
        orderRow.tap()
        app.buttons["撤销出库"].tap()
        type(into: app.textFields["撤销原因（必填）"], "UI 测试撤销")
        app.buttons["撤销"].tap()
        app.buttons["确定撤销"].tap()
        XCTAssertTrue(app.staticTexts["已撤销"].firstMatch.waitForExistence(timeout: 10))
        waitForText(containing: "UI 测试撤销", timeout: 5)  // 显示撤销原因
    }
}

extension XCUIElement {
    func clearAndType(_ text: String) {
        tap()
        if let value = value as? String, !value.isEmpty {
            typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count))
        }
        typeText(text)
    }
}
