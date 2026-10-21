import Foundation
import Testing
@testable import Mantenimiento

struct StatusPopoverLayoutTests {
    @Test func showsAllContentWhenItFits() {
        #expect(StatusPopoverLayout.height(contentHeight: 742.2, availableHeight: 900) == 743)
    }

    @Test func neverExceedsAvailableScreenHeight() {
        #expect(StatusPopoverLayout.height(contentHeight: 940, availableHeight: 600) == 600)
        #expect(StatusPopoverLayout.height(contentHeight: 940, availableHeight: 120) == 120)
    }

    @Test func maintainsUsableMinimumForInitialEmptyContent() {
        #expect(StatusPopoverLayout.height(contentHeight: 0, availableHeight: 900) == 180)
    }
}
