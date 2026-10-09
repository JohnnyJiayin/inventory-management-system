import XCTest

/// Sprint 1 端到端流程（在模拟器 + 本地 supabase 上运行）
///   前提：supabase start；本地已创建测试账号；ios/Config/Secrets.xcconfig 指向本地 supabase。
///   账号通过 scheme 的环境变量 UITEST_EMAIL / UITEST_PASSWORD 提供（只用于本地测试库）。
final class Sprint1FlowTests: XCTestCase {
    private var app: XCUIApplication!
    private let env = ProcessInfo.processInfo.environment

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        addUIInterruptionMonitor(withDescription: "权限") { alert in
            for label in ["允许", "Allow", "OK", "好"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
    }

    func testFullSprint1Flow() throws {
        let email = try XCTUnwrap(env["UITEST_EMAIL"])
        let password = try XCTUnwrap(env["UITEST_PASSWORD"])
        app.launch()
        signOutIfNeeded()

        // 登录：密码错误有明确提示
        let emailField = app.textFields["邮箱"]
        XCTAssertTrue(emailField.waitForExistence(timeout: 10), "首次打开需要登录")
        emailField.tap()
        emailField.typeText(email)
        let passwordField = app.secureTextFields["密码"]
        passwordField.tap()
        passwordField.typeText("wrong-password")
        app.buttons["登录"].tap()
        XCTAssertTrue(app.staticTexts["邮箱或密码错误"].waitForExistence(timeout: 10), "密码错误提示")

        // 重新打开 App（没有会话时仍停留在登录页），输入正确密码
        app.terminate()
        app.launch()
        type(into: app.textFields["邮箱"], email)
        type(into: app.secureTextFields["密码"], password)
        app.buttons["登录"].tap()
        XCTAssertTrue(sidebar("产品管理").waitForExistence(timeout: 10), "登录后进入主界面")

        // 重启 App 不需要重新登录
        app.terminate()
        app.launch()
        XCTAssertTrue(sidebar("产品管理").waitForExistence(timeout: 10), "重启后保持登录")
        XCTAssertFalse(app.textFields["邮箱"].exists)

        // 产品建档：不上传照片，初始数量 0
        let tag = String(Int(Date().timeIntervalSince1970))
        let barcode = "UIT\(tag)"
        sidebar("产品管理").tap()
        app.buttons["添加产品"].tap()
        type(into: app.textFields["产品名称（必填）"], "测试功放")
        type(into: app.textFields["产品型号（必填）"], "AMP-\(tag)")
        type(into: app.textFields["产品条码（必填，扫描或手动输入）"], barcode)
        app.buttons["保存"].tap()
        XCTAssertTrue(app.staticTexts["AMP-\(tag)"].waitForExistence(timeout: 10), "新建的型号立即出现在列表中")

        // 重复条码显示明确错误
        app.buttons["添加产品"].tap()
        type(into: app.textFields["产品名称（必填）"], "重复")
        type(into: app.textFields["产品型号（必填）"], "DUP")
        type(into: app.textFields["产品条码（必填，扫描或手动输入）"], barcode)
        app.buttons["保存"].tap()
        XCTAssertTrue(app.staticTexts["产品条码 \(barcode) 已被型号「测试功放 AMP-\(tag)」使用"].waitForExistence(timeout: 10))
        app.buttons["取消"].tap()

        // 入库：扫产品条码（手动输入）→ 计划 2 台 → 扫两个机身号 → 确认
        sidebar("入库").tap()
        manualInput(barcode)
        XCTAssertTrue(app.staticTexts["已识别：测试功放 AMP-\(tag)，当前库存 0"].waitForExistence(timeout: 10))
        app.steppers.firstMatch.buttons.element(boundBy: 1).tap() // 计划数量 1 → 2
        manualInput("S1")
        XCTAssertTrue(app.staticTexts["已加入：S1（首次入库）"].waitForExistence(timeout: 10))
        manualInput("S1")
        XCTAssertTrue(app.staticTexts["机身号 S1 已在清单中"].waitForExistence(timeout: 10))
        let confirm = app.buttons["确认入库（1 台）"]
        XCTAssertFalse(confirm.isEnabled, "扫描数量不等于计划数量时不能确认")
        manualInput("S2")
        app.buttons["确认入库（2 台）"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '入库成功：RK'")).firstMatch
            .waitForExistence(timeout: 10))

        // 已在库的机身号被拒绝
        manualInput("S1")
        XCTAssertTrue(app.staticTexts["机身号 S1 已在库，不能重复入库"].waitForExistence(timeout: 10))

        // 产品列表库存为 2；有记录的型号只能停用
        sidebar("产品管理").tap()
        let row = app.staticTexts["AMP-\(tag)"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(app.buttons["停用产品"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["删除产品"].exists)
        app.buttons["停用产品"].tap()
        app.buttons["停用"].firstMatch.tap()
        XCTAssertTrue(app.buttons["重新启用"].waitForExistence(timeout: 10))

        // 停用后扫描该型号条码入库时提示已停用
        sidebar("入库").tap()
        manualInput(barcode)
        XCTAssertTrue(app.staticTexts["“测试功放 AMP-\(tag)”已停用，不能入库"].waitForExistence(timeout: 10))

        // 未知条码 → 绑定已有型号 → 再次扫描自动识别
        let unknown = "UNK\(tag)"
        manualInput(unknown)
        XCTAssertTrue(app.staticTexts["未找到对应产品型号，请创建产品或绑定已有型号。"].waitForExistence(timeout: 10))
        app.buttons["创建新型号"].tap()
        type(into: app.textFields["产品名称（必填）"], "新音箱")
        type(into: app.textFields["产品型号（必填）"], "SPK-\(tag)")
        app.buttons["保存"].tap()
        XCTAssertTrue(app.staticTexts["已识别：新音箱 SPK-\(tag)，当前库存 0"].waitForExistence(timeout: 10),
                      "创建后回到入库流程继续")
        app.buttons["更换型号"].tap()
        manualInput(unknown)
        XCTAssertTrue(app.staticTexts["已识别：新音箱 SPK-\(tag)，当前库存 0"].waitForExistence(timeout: 10),
                      "再次扫描同一条码自动识别型号")

        // 设置里退出登录
        sidebar("设置").tap()
        app.buttons["退出登录"].firstMatch.tap()
        app.buttons["退出登录"].firstMatch.tap()
        XCTAssertTrue(app.textFields["邮箱"].waitForExistence(timeout: 10))
    }

    /// 重新入库（Issue #21）。依赖 supabase/seed.sql 中的演示数据：
    /// 型号 DEMO-RESTOCK 的机身号 R1 已出库。每次运行前执行 supabase db reset。
    func testRestockFlow() throws {
        app.launch()
        try loginIfNeeded()
        sidebar("入库").tap()
        manualInput("DEMO-RESTOCK")
        XCTAssertTrue(app.staticTexts["已识别：演示功放 4.4 AMP，当前库存 1"].waitForExistence(timeout: 10))
        manualInput("R1")
        let alert = app.alerts["该产品曾经出库，是否重新入库"]
        guard alert.waitForExistence(timeout: 10) else {
            throw XCTSkip("R1 不是已出库状态，请先 supabase db reset")
        }
        alert.buttons["重新入库"].tap()
        XCTAssertTrue(app.staticTexts["已加入：R1（重新入库）"].waitForExistence(timeout: 10))
        app.buttons["确认入库（1 台）"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS '首次入库 0，重新入库 1'")).firstMatch
            .waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["2"].waitForExistence(timeout: 10), "重新入库后库存加 1")
    }

    // MARK: - helpers

    private func loginIfNeeded() throws {
        let emailField = app.textFields["邮箱"]
        guard emailField.waitForExistence(timeout: 5) else { return }
        type(into: emailField, try XCTUnwrap(env["UITEST_EMAIL"]))
        type(into: app.secureTextFields["密码"], try XCTUnwrap(env["UITEST_PASSWORD"]))
        app.buttons["登录"].tap()
        XCTAssertTrue(sidebar("入库").waitForExistence(timeout: 10))
    }

    private func sidebar(_ title: String) -> XCUIElement {
        let cell = app.collectionViews.buttons[title]
        if cell.exists { return cell }
        return app.buttons[title].firstMatch
    }

    private func type(into field: XCUIElement, _ text: String) {
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(text)
    }

    private func manualInput(_ code: String) {
        let button = app.buttons["手动输入"]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        button.tap()
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText(code)
        app.alerts.buttons["确定"].tap()
    }

    private func signOutIfNeeded() {
        let settings = sidebar("设置")
        if settings.waitForExistence(timeout: 5) {
            settings.tap()
            app.buttons["退出登录"].firstMatch.tap()
            app.buttons["退出登录"].firstMatch.tap()
        }
    }
}
