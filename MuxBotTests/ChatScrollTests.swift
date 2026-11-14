import Foundation
import Testing
@testable import MuxBot

/// The transcript follows the newest message only when the content or the
/// window changed size, and your own scrolling decides whether it follows.
struct ChatScrollTests {
    @Test func aGrowingCardIsALayoutChangeNotAScroll() {
        let before = ScrollMetrics(contentHeight: 800, visibleHeight: 400, distanceFromBottom: 0)
        let grown = ScrollMetrics(contentHeight: 1100, visibleHeight: 400, distanceFromBottom: 300)
        #expect(grown.layoutDiffers(from: before))
    }

    @Test func theShelfAppearingIsALayoutChange() {
        let before = ScrollMetrics(contentHeight: 800, visibleHeight: 400, distanceFromBottom: 0)
        let shelf = ScrollMetrics(contentHeight: 800, visibleHeight: 360, distanceFromBottom: 40)
        #expect(shelf.layoutDiffers(from: before))
    }

    @Test func scrollingUpIsNotALayoutChange() {
        let before = ScrollMetrics(contentHeight: 800, visibleHeight: 400, distanceFromBottom: 0)
        let up = ScrollMetrics(contentHeight: 800, visibleHeight: 400, distanceFromBottom: 250)
        #expect(!up.layoutDiffers(from: before))
    }
}
