import XCTest
import AppKit
@testable import QuickMarkview

final class ZoomStateTests: XCTestCase {
    func testStepsResetAndLimits() {
        var state = ZoomState()
        XCTAssertFalse(state.apply(action: .reset))
        XCTAssertTrue(state.apply(action: .in))
        XCTAssertEqual(state.percent, 110)
        XCTAssertEqual(state.pageZoom, 1.1, accuracy: 0.001)
        XCTAssertTrue(state.apply(action: .out))
        XCTAssertEqual(state.percent, 100)
        for _ in 0..<30 { state.apply(action: .out) }
        XCTAssertEqual(state.percent, 50)
        XCTAssertFalse(state.apply(action: .out))
        XCTAssertTrue(state.apply(action: .reset))
        for _ in 0..<30 { state.apply(action: .in) }
        XCTAssertEqual(state.percent, 200)
        XCTAssertFalse(state.apply(action: .in))
        XCTAssertTrue(state.apply(action: .reset))
        XCTAssertEqual(state.percent, 100)
    }
}

@MainActor
final class ZoomToastTests: XCTestCase {
    func testDeadlineRenewalAndDismissIgnoreOldCallbacks() {
        var callbacks: [@MainActor () -> Void] = []
        var cancellations = 0
        let toast = ZoomToastView { delay, callback in
            XCTAssertEqual(delay, 3)
            callbacks.append(callback)
            return { cancellations += 1 }
        }
        toast.show(percent: 110)
        XCTAssertFalse(toast.isHidden)
        XCTAssertEqual(toast.text, "Zoom 110%")
        toast.show(percent: 120)
        XCTAssertEqual(cancellations, 1)
        callbacks[0]() // Even an already-enqueued callback cannot hide the new toast.
        XCTAssertFalse(toast.isHidden)
        XCTAssertEqual(toast.text, "Zoom 120%")
        callbacks[1]()
        XCTAssertTrue(toast.isHidden)
        toast.show(percent: 100)
        toast.dismiss()
        toast.show(percent: 90)
        callbacks[2]()
        XCTAssertFalse(toast.isHidden)
        XCTAssertEqual(toast.text, "Zoom 90%")
        XCTAssertNil(toast.hitTest(.zero))
        callbacks[3]()
        XCTAssertTrue(toast.isHidden)
    }
}
