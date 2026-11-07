import XCTest
@testable import scout

final class CommandTests: XCTestCase {
    func testCommandName() {
        XCTAssertEqual(Scout.configuration.commandName, "scout")
    }
}
