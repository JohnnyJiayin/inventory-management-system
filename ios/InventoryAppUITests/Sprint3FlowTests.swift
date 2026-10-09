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
}
