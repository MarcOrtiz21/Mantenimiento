import AppKit

final class CleanOverlayWindow: NSWindow {
    private let overlayView = CleanOverlayView()

    init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        isReleasedWhenClosed = false
        level = .screenSaver
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = false
        collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .ignoresCycle,
            .stationary
        ]

        contentView = overlayView
    }

    func update(remainingSeconds: Int) {
        overlayView.update(remainingSeconds: remainingSeconds)
    }
}

final class CleanOverlayView: NSView {
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "Modo Limpieza")
    private let countdownLabel = NSTextField(labelWithString: "00:00")
    private let detailLabel = NSTextField(labelWithString: "Teclado, trackpad y ratón bloqueados")
    private let emergencyLabel = NSTextField(labelWithString: "Emergencia: Control + Option + Command + Esc")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.backgroundColor = .clear
    }

    private func configure() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.88).cgColor

        iconView.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "Bloqueado")
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 42, weight: .semibold)
        iconView.contentTintColor = .white
        iconView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 28, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.alignment = .center

        countdownLabel.font = .monospacedDigitSystemFont(ofSize: 72, weight: .medium)
        countdownLabel.textColor = .white
        countdownLabel.alignment = .center

        detailLabel.font = .systemFont(ofSize: 16, weight: .regular)
        detailLabel.textColor = NSColor.white.withAlphaComponent(0.82)
        detailLabel.alignment = .center

        emergencyLabel.font = .systemFont(ofSize: 13, weight: .regular)
        emergencyLabel.textColor = NSColor.white.withAlphaComponent(0.62)
        emergencyLabel.alignment = .center

        [titleLabel, countdownLabel, detailLabel, emergencyLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            $0.lineBreakMode = .byTruncatingTail
            $0.maximumNumberOfLines = 2
        }

        let stack = NSStackView(views: [
            iconView,
            titleLabel,
            countdownLabel,
            detailLabel,
            emergencyLabel
        ])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stack)

        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 56),
            iconView.heightAnchor.constraint(equalToConstant: 56),

            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -32)
        ])
    }

    func update(remainingSeconds: Int) {
        let minutes = remainingSeconds / 60
        let seconds = remainingSeconds % 60
        countdownLabel.stringValue = String(format: "%02d:%02d", minutes, seconds)
    }
}
