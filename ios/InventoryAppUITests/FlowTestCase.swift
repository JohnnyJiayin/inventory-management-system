import XCTest

/// UI 测试公共部分：启动、登录、侧边栏导航、手动输入条码
///   前提：supabase start；本地已创建测试账号；ios/Config/Secrets.xcconfig 指向本地 supabase。
///   账号通过 scheme 的环境变量 UITEST_EMAIL / UITEST_PASSWORD 提供（只用于本地测试库）。
class FlowTestCase: XCTestCase {
    var app: XCUIApplication!
    let env = ProcessInfo.processInfo.environment

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

    func loginIfNeeded() throws {
        let emailField = app.textFields["邮箱"]
        guard emailField.waitForExistence(timeout: 5) else { return }
        type(into: emailField, try XCTUnwrap(env["UITEST_EMAIL"]))
        type(into: app.secureTextFields["密码"], try XCTUnwrap(env["UITEST_PASSWORD"]))
        app.buttons["登录"].tap()
        XCTAssertTrue(sidebar("入库").waitForExistence(timeout: 10))
    }

    func sidebar(_ title: String) -> XCUIElement {
        let cell = app.collectionViews.buttons[title]
        if cell.exists { return cell }
        return app.buttons[title].firstMatch
    }

    func type(into field: XCUIElement, _ text: String) {
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(text)
    }

    func manualInput(_ code: String) {
        let button = app.buttons["手动输入"]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        button.tap()
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText(code)
        app.alerts.buttons["确定"].tap()
    }

    func signOutIfNeeded() {
        let settings = sidebar("设置")
        if settings.waitForExistence(timeout: 5) {
            settings.tap()
            app.buttons["退出登录"].firstMatch.tap()
            app.buttons["退出登录"].firstMatch.tap()
        }
    }

    /// 等待包含指定文字的静态文本出现
    @discardableResult
    func waitForText(containing text: String, timeout: TimeInterval = 10) -> XCUIElement {
        let element = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "应显示：\(text)")
        return element
    }
}
