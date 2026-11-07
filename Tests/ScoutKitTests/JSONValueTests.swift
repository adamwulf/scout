import Foundation
import XCTest
@testable import ScoutKit

final class JSONValueTests: XCTestCase {
    func testKeepsOptionalFieldsAndIntegerIDs() throws {
        let data = Data(#"{"id":123,"unknown":{"flag":true},"value":null}"#.utf8)
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(try value.requiredID(), 123)
        XCTAssertEqual(value["unknown"]["flag"], .bool(true))
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value)), value)
    }
}
