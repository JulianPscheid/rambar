import Foundation
import XCTest
@testable import RambarFace

@MainActor
final class FaceModelTests: XCTestCase {
    func testGroupByAppDefaultsToFalse() {
        withDefaults { defaults in
            XCTAssertFalse(FaceModel(defaults: defaults).groupByApp)
        }
    }

    func testGroupByAppPersistsRoundTrip() {
        withDefaults { defaults in
            let model = FaceModel(defaults: defaults)
            model.setGroupByApp(true)
            XCTAssertTrue(FaceModel(defaults: defaults).groupByApp)

            model.setGroupByApp(false)
            XCTAssertFalse(FaceModel(defaults: defaults).groupByApp)
        }
    }

    private func withDefaults(_ body: (UserDefaults) -> Void) {
        let suiteName = "FaceModelTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create isolated UserDefaults")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        body(defaults)
    }
}
