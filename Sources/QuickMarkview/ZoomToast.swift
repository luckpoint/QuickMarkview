import AppKit

@MainActor
final class ZoomToastView: NSVisualEffectView {
    typealias Scheduler = @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> () -> Void
    private let label = NSTextField(labelWithString: "")
    private let schedule: Scheduler
    private var cancelHide: (() -> Void)?
    private var generation: UInt64 = 0
    var text: String { label.stringValue }

    init(schedule: @escaping Scheduler = ZoomToastView.scheduleHide) {
        self.schedule = schedule
        super.init(frame: .zero)
        material = .popover
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 8
        isHidden = true
        label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(percent: Int) {
        dismiss()
        label.stringValue = "Zoom \(percent)%"
        isHidden = false
        let currentGeneration = generation
        cancelHide = schedule(3) { [weak self] in
            guard let self, self.generation == currentGeneration else { return }
            self.dismiss()
        }
    }

    func dismiss() {
        generation &+= 1
        cancelHide?()
        cancelHide = nil
        isHidden = true
    }

    private static func scheduleHide(after delay: TimeInterval, action: @escaping @MainActor () -> Void) -> () -> Void {
        let task = Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            action()
        }
        return { task.cancel() }
    }
}
