import Foundation

struct ZoomState {
    enum Action: String { case `in`, reset, out }
    private(set) var percent = 100
    var pageZoom: CGFloat { CGFloat(percent) / 100 }

    @discardableResult
    mutating func apply(action: Action) -> Bool {
        let previous = percent
        switch action {
        case .in: percent = min(200, percent + 10)
        case .reset: percent = 100
        case .out: percent = max(50, percent - 10)
        }
        return percent != previous
    }
}
