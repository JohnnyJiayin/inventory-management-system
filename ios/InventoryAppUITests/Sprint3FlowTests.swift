import XCTest

/// Sprint 3：首页、库存多条件查询、产品详情记录。
/// 依赖 supabase/seed.sql 中的演示数据：型号 DEMO-OUT（演示音箱 SPK-1），机身号 O1–O5。只读，不修改数据。
final class Sprint3FlowTests: FlowTestCase {
    func testHomeInventoryAndDetail() throws {
        app.launch()
        try loginIfNeeded()

        // ---------------------------------------------------------------- 首页
        sidebar("首页").tap()
        waitForText(containing: "当前库存总数")
        waitForText(containing: "当月销售金额")
        // 点击“即将过保”跳转到保修查询，并已选中“即将过保”
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH '即将过保'")).firstMatch.tap()
        XCTAssertTrue(app.navigationBars["保修查询"].waitForExistence(timeout: 10), "跳转到保修查询")
        XCTAssertTrue(app.buttons["即将过保"].isSelected, "保修状态预先选中即将过保")

        // ---------------------------------------------------------------- 库存多条件查询
        sidebar("产品管理").tap()
        waitForText(containing: "累计入库")
        app.buttons["筛选"].tap()
        type(into: app.textFields["机身号（包含即可）"], "O3")
        app.buttons["完成"].tap()
        waitForText(containing: "已设置 1 个筛选条件，共 1 个型号")
        let row = app.staticTexts["演示音箱"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "按机身号查到演示音箱")
        app.buttons["清除"].tap()
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS '个筛选条件'")).firstMatch
            .waitForExistence(timeout: 2), "清除后不再显示筛选条件")

        // ---------------------------------------------------------------- 产品详情记录
        app.staticTexts["演示音箱"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["出入库与保修记录"].waitForExistence(timeout: 10) ||
                      app.staticTexts["出入库与保修记录".uppercased()].exists)
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH '入库记录'")).firstMatch.tap()
        let serialFilter = app.textFields["按机身号筛选"]
        type(into: serialFilter, "O4")
        waitForText(containing: "O4")
        waitForText(containing: "首次入库")
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH '出库记录'")).firstMatch.tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH '保修'")).firstMatch.tap()
        XCTAssertTrue(app.switches.matching(NSPredicate(format: "label BEGINSWITH '只看当前保修'")).firstMatch
            .waitForExistence(timeout: 5), "保修记录可切换历史记录")
    }

    /// 报表：五类报表、筛选条件在切换报表时保留、三种格式导出（导出文件在测试后从模拟器取出检查）
    func testReportsAndExport() throws {
        app.launch()
        try loginIfNeeded()
        sidebar("报表").tap()
        XCTAssertTrue(app.navigationBars["月度统计"].waitForExistence(timeout: 10))

        // 筛选：全部时间；切换报表后保持
        app.segmentedControls.buttons["全部时间"].tap()
        XCTAssertTrue(app.staticTexts["合计"].waitForExistence(timeout: 10), "月度统计有合计行")
        for (segment, table) in [("经销商", "经销商统计"), ("型号", "产品型号统计"), ("运费", "每月运费汇总"), ("保修", "保修数量")] {
            app.segmentedControls.buttons[segment].tap()
            XCTAssertTrue(app.staticTexts[table].waitForExistence(timeout: 10), "显示\(table)")
            XCTAssertTrue(app.segmentedControls.buttons["全部时间"].isSelected, "切换到\(segment)后保留筛选条件")
        }

        // 导出：运费统计（含三个表格）分别导出三种格式
        app.segmentedControls.buttons["运费"].tap()
        XCTAssertTrue(app.staticTexts["订单运费明细"].waitForExistence(timeout: 10))
        for format in ["Excel（.xlsx）", "CSV", "PDF"] {
            app.buttons["导出"].tap()
            app.buttons[format].tap()
            // 系统分享面板出现后关闭
            let share = app.otherElements["ActivityListView"].firstMatch
            let appeared = share.waitForExistence(timeout: 10)
                || app.collectionViews.cells.firstMatch.waitForExistence(timeout: 5)
            XCTAssertTrue(appeared, "\(format) 导出后显示分享面板")
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.5)).tap()
            XCTAssertTrue(app.buttons["导出"].waitForExistence(timeout: 10))
        }
    }

    /// 横竖屏检查（Issue #53）：竖屏和横屏下依次打开各页面并截图（截图保存在测试结果中，人工查看）
    func testOrientationTour() throws {
        app.launch()
        try loginIfNeeded()
        let pages = ["首页", "产品管理", "入库", "出库订单", "经销商", "保修查询", "报表", "设置"]
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            let name = orientation == .portrait ? "竖屏" : "横屏"
            for page in pages {
                // 竖屏时侧边栏可能收起，先打开
                if !sidebar(page).isHittable, app.buttons["Show Sidebar"].exists { app.buttons["Show Sidebar"].tap() }
                sidebar(page).tap()
                XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 10))
                sleep(2)
                attach("\(name)-\(page)")
            }
        }
        XCUIDevice.shared.orientation = .portrait
    }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
