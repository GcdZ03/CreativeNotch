import Foundation
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// The empty shelf's promise about how long files stay (2026-10-24).
///
/// It used to read a constant; with the expiry chosen in Settings it reads
/// the store's, so the line under the drop target never promises a week to
/// a shelf set to a day — or an expiry to one set to never.
@MainActor
struct DropTargetRetentionTests {

    @Test func itStatesTheChosenExpiryInDays() {
        #expect(DropTargetView.retentionLine(maxAge: ShelfExpiry.sevenDays.maxAge)
                == "Kept 7 days · drag them out anywhere")
        #expect(DropTargetView.retentionLine(maxAge: ShelfExpiry.thirtyDays.maxAge)
                == "Kept 30 days · drag them out anywhere")
    }

    @Test func oneDayIsSingular() {
        #expect(DropTargetView.retentionLine(maxAge: ShelfExpiry.oneDay.maxAge)
                == "Kept 1 day · drag them out anywhere")
    }

    @Test func neverPromisesNoExpiry() {
        #expect(DropTargetView.retentionLine(maxAge: nil)
                == "Kept until you remove them · drag them out anywhere")
    }

    /// The shelf view hands over its store's age, not the default.
    @Test func theTargetReadsTheStoresExpiry() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CreativeNotchRetention-\(UUID().uuidString)")
        let store = try ShelfStore(directory: dir, maxAge: nil, trash: TestTrash.shelf)
        #expect(ShelfView.emptyTarget(for: store).maxAge == nil)
    }
}
