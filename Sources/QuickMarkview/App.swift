import AppKit
import UniformTypeIdentifiers
import WebKit

@main
@MainActor
struct QuickMarkviewMain {
    static func main() {
        do {
            let options = try LaunchOptions()
            if options.showHelp { print(quickMarkviewUsage); return }
            let application = NSApplication.shared
            application.setActivationPolicy(.regular)
            let delegate = AppDelegate(options: options)
            application.delegate = delegate
            withExtendedLifetime(delegate) { application.run() }
        } catch {
            FileHandle.standardError.write(Data("QuickMarkview: \(error.localizedDescription)\n".utf8))
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var controller: ViewerViewController!
    private let options: LaunchOptions

    init(options: LaunchOptions) { self.options = options; super.init() }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenus()
        controller = ViewerViewController(options: options)
        window = NSWindow(contentViewController: controller)
        window.title = "QuickMarkview"
        window.setContentSize(NSSize(width: 1200, height: 820))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let window = self?.window, event.window === window,
                  Self.closesViewer(characters: event.characters, firstResponder: window.firstResponder) else { return event }
            NSApp.terminate(nil)
            return nil
        }
    }

    static func closesViewer(characters: String?, firstResponder: NSResponder?) -> Bool {
        characters == "q" && !(firstResponder is NSText)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if let url = urls.first { controller?.open(url: url, line: nil) }
    }

    private func installMenus() {
        let menu = NSMenu()
        let appItem = NSMenuItem(); let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About QuickMarkview", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit QuickMarkview", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu; menu.addItem(appItem)

        let editItem = NSMenuItem(); let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu; menu.addItem(editItem)
        NSApp.mainMenu = menu
    }

    private func showFatal(_ message: String) {
        let alert = NSAlert(); alert.messageText = "QuickMarkview"; alert.informativeText = message; alert.alertStyle = .critical; alert.runModal(); NSApp.terminate(nil)
    }
}

@MainActor
final class ViewerViewController: NSViewController, WKNavigationDelegate, WKScriptMessageHandler, NSTextFieldDelegate, NSTextViewDelegate {
    private let options: LaunchOptions
    private let service = WezTermService()
    private var watcher: FileWatcher?
    private var document: MarkdownDocument?
    private var selection: RenderedSelection?
    private var revision: UInt64 = 0
    private var webReady = false
    private var queuedSource: String?
    private var queuedLine: Int?
    private var originPaneID: Int?
    private var targetPanes: [WezTermPane] = []
    private var explicitTargetID: Int?
    private var viewerDirectoryURL: URL?
    private var isSending = false
    private var splitView: NSSplitView!
    private var didSetInitialSplitPosition = false

    private let pathLabel = NSTextField(labelWithString: "No file open")
    private let lineLabel = NSTextField(labelWithString: "")
    private let requestField = NSTextField(string: "")
    private let targetPopup = NSPopUpButton()
    private let openButton = NSButton(title: "Open…", target: nil, action: nil)
    private let sendButton = NSButton(title: "Send to Agent", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "Select rendered text to prepare a request.")
    private let selectedLabel = NSTextField(labelWithString: "No rendered selection")
    private let promptView = NSTextView()
    private var webView: WKWebView!

    init(options: LaunchOptions) {
        self.options = options
        self.originPaneID = options.originPaneID ?? Int(ProcessInfo.processInfo.environment["WEZTERM_PANE"] ?? "")
        self.explicitTargetID = options.targetPaneID
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let root = NSView(); root.wantsLayer = true
        let toolbar = makeToolbar()
        let split = NSSplitView(); split.isVertical = false; split.dividerStyle = .thin; splitView = split
        let browser = NSView(); browser.translatesAutoresizingMaskIntoConstraints = false; let page = makeWebView(); browser.addSubview(page); _ = constrained(page)
        let review = makeReviewView()
        split.addArrangedSubview(browser); split.addArrangedSubview(review)
        browser.heightAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        review.heightAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true

        let stack = NSStackView(views: [toolbar, split]); stack.orientation = .vertical; stack.alignment = .width; stack.distribution = .fill; stack.spacing = 0; stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            toolbar.heightAnchor.constraint(equalToConstant: 46), toolbar.widthAnchor.constraint(equalTo: root.widthAnchor), split.widthAnchor.constraint(equalTo: root.widthAnchor), split.heightAnchor.constraint(greaterThanOrEqualToConstant: 520),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor), stack.trailingAnchor.constraint(equalTo: root.trailingAnchor), stack.topAnchor.constraint(equalTo: root.topAnchor), stack.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        self.view = root
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if let url = options.fileURL { open(url: url, line: options.line) }
        else if options.showHelp == false && document == nil { chooseFile(nil) }
        view.window?.makeFirstResponder(webView)
        refreshTargets()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        guard !didSetInitialSplitPosition, splitView.bounds.height > 520 else { return }
        didSetInitialSplitPosition = true
        splitView.setPosition(max(300, splitView.bounds.height - 250), ofDividerAt: 0)
    }

    private func makeToolbar() -> NSView {
        openButton.target = self; openButton.action = #selector(chooseFile(_:)); openButton.bezelStyle = .rounded
        pathLabel.font = .systemFont(ofSize: 12); pathLabel.lineBreakMode = .byTruncatingMiddle; pathLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        lineLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular); lineLabel.textColor = .secondaryLabelColor
        requestField.placeholderString = "Request (or /btw …)"; requestField.delegate = self; requestField.target = self; requestField.action = #selector(requestChanged(_:)); requestField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        targetPopup.addItem(withTitle: "Target pane"); targetPopup.target = self; targetPopup.action = #selector(targetChanged(_:)); targetPopup.setContentHuggingPriority(.required, for: .horizontal)
        sendButton.target = self; sendButton.action = #selector(sendPrompt(_:)); sendButton.isEnabled = false; sendButton.bezelStyle = .rounded
        let stack = NSStackView(views: [openButton, pathLabel, lineLabel, requestField, targetPopup, sendButton]); stack.orientation = .horizontal; stack.spacing = 8; stack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10); stack.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView(); container.addSubview(stack); NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: container.leadingAnchor), stack.trailingAnchor.constraint(equalTo: container.trailingAnchor), stack.topAnchor.constraint(equalTo: container.topAnchor), stack.bottomAnchor.constraint(equalTo: container.bottomAnchor)])
        return container
    }

    private func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration(); let controller = WKUserContentController(); controller.add(self, name: "quickMarkview"); configuration.userContentController = controller
        webView = WKWebView(frame: .zero, configuration: configuration); webView.navigationDelegate = self; webView.translatesAutoresizingMaskIntoConstraints = false
        if let viewer = Self.viewerResourceURL() { viewerDirectoryURL = viewer.deletingLastPathComponent(); webView.loadFileURL(viewer, allowingReadAccessTo: viewer.deletingLastPathComponent()) }
        return webView
    }

    private static func viewerResourceURL() -> URL? {
        let executableDirectory = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.deletingLastPathComponent()
        let mainRoot = Bundle.main.bundleURL.standardizedFileURL
        let candidates = [
            mainRoot.appendingPathComponent("QuickMarkview_QuickMarkview.bundle/viewer.html"),
            mainRoot.appendingPathComponent("Resources/QuickMarkview_QuickMarkview.bundle/viewer.html"),
            mainRoot.appendingPathComponent("Contents/Resources/QuickMarkview_QuickMarkview.bundle/viewer.html"),
            executableDirectory.appendingPathComponent("QuickMarkview_QuickMarkview.bundle/viewer.html")
        ]
        return candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) })
    }

    private func constrained(_ view: NSView) -> NSView { view.translatesAutoresizingMaskIntoConstraints = false; if let superview = view.superview { NSLayoutConstraint.activate([view.leadingAnchor.constraint(equalTo: superview.leadingAnchor), view.trailingAnchor.constraint(equalTo: superview.trailingAnchor), view.topAnchor.constraint(equalTo: superview.topAnchor), view.bottomAnchor.constraint(equalTo: superview.bottomAnchor)]) }; return view }

    private func makeReviewView() -> NSView {
        selectedLabel.font = .systemFont(ofSize: 11); selectedLabel.textColor = .secondaryLabelColor; selectedLabel.lineBreakMode = .byTruncatingTail
        statusLabel.font = .systemFont(ofSize: 11); statusLabel.textColor = .secondaryLabelColor; statusLabel.lineBreakMode = .byTruncatingTail
        promptView.isEditable = true; promptView.isSelectable = true; promptView.font = .monospacedSystemFont(ofSize: 12, weight: .regular); promptView.textContainerInset = NSSize(width: 10, height: 10); promptView.delegate = self
        let promptScroll = NSScrollView(); promptScroll.hasVerticalScroller = true; promptScroll.documentView = promptView
        let labels = NSStackView(views: [selectedLabel, statusLabel]); labels.orientation = .vertical; labels.alignment = .width; labels.spacing = 4
        let title = NSTextField(labelWithString: "Review request before sending"); title.font = .boldSystemFont(ofSize: 12)
        let stack = NSStackView(views: [title, labels, promptScroll]); stack.orientation = .vertical; stack.alignment = .width; stack.distribution = .fill; stack.spacing = 8; stack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10); stack.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView(); container.addSubview(stack); NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: container.leadingAnchor), stack.trailingAnchor.constraint(equalTo: container.trailingAnchor), stack.topAnchor.constraint(equalTo: container.topAnchor), stack.bottomAnchor.constraint(equalTo: container.bottomAnchor), promptScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 150)])
        return container
    }

    func open(url: URL, line: Int?) {
        let url = url.standardizedFileURL
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            revision &+= 1
            document = MarkdownDocument(url: url, text: text, revision: revision)
            selection = nil; promptView.string = ""; sendButton.isEnabled = false
            pathLabel.stringValue = url.path; lineLabel.stringValue = line.map { "line \($0)" } ?? ""
            statusLabel.stringValue = "Select rendered text to prepare a request."
            watcher?.stop(); watcher = FileWatcher(fileURL: url) { [weak self] in DispatchQueue.main.async { self?.reloadAfterExternalChange() } }; watcher?.start()
            queuedSource = text; queuedLine = line; renderCurrentDocument()
        } catch { statusLabel.stringValue = "Could not open file: \(error.localizedDescription)" }
    }

    private func reloadAfterExternalChange() {
        guard let url = document?.url else { return }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            guard text != document?.text else { return }
            revision &+= 1; document = MarkdownDocument(url: url, text: text, revision: revision)
            selection = nil; promptView.string = ""; sendButton.isEnabled = false
            selectedLabel.stringValue = "Selection cleared after file reload. Select text again."
            queuedSource = text; queuedLine = nil; renderCurrentDocument()
        } catch { statusLabel.stringValue = "File changed but could not be read: \(error.localizedDescription)" }
    }

    private func renderCurrentDocument() {
        guard webReady, let source = queuedSource else { return }
        // JSONEncoder safely handles a scalar String without interpolating
        // user content into executable JavaScript.
        let sourceLiteral = (try? String(data: JSONEncoder().encode(source), encoding: .utf8)) ?? "\"\""
        let lineLiteral = queuedLine.map(String.init) ?? "null"
        webView.evaluateJavaScript("window.quickMarkview.setDocument(\(sourceLiteral), \(lineLiteral), \(revision));", completionHandler: nil)
        queuedSource = nil
    }

    @objc private func chooseFile(_ sender: Any?) {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.text, .plainText, .init(filenameExtension: "md")!, .init(filenameExtension: "markdown")!]; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { open(url: url, line: nil) }
    }

    private func updatePrompt() {
        guard let document, let selection, selection.revision == revision else { return }
        promptView.string = PromptBuilder.build(context: document, range: selection.sourceRange, request: requestField.stringValue, selectedText: selection.text)
        updateSendButtonState()
    }

    @objc private func requestChanged(_ sender: Any?) { updatePrompt() }
    @objc private func targetChanged(_ sender: Any?) { explicitTargetID = targetPopup.selectedItem?.representedObject as? Int; updateSendButtonState() }

    private func updateSendButtonState() {
        sendButton.isEnabled = Self.canSend(prompt: promptView.string, selectionIsCurrent: selection?.revision == revision, hasTarget: targetPanes.count == 1 || explicitTargetID != nil, hasOrigin: originPaneID != nil, isSending: isSending)
    }

    static func canSend(prompt: String, selectionIsCurrent: Bool, hasTarget: Bool, hasOrigin: Bool, isSending: Bool) -> Bool {
        !isSending && hasTarget && hasOrigin && selectionIsCurrent && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func refreshTargets() {
        guard let originPaneID else { statusLabel.stringValue = "WEZTERM_PANE is not set; open from WezTerm or pass --pane."; return }
        service.listPanes { [weak self] result in DispatchQueue.main.async {
            guard let self else { return }
            switch result {
            case .failure(let error): self.targetPanes = []; self.statusLabel.stringValue = error.localizedDescription; self.updateSendButtonState()
            case .success(let panes):
                do {
                    self.targetPanes = try PaneTargetResolver.resolve(panes: panes, currentPaneID: originPaneID, explicitTargetID: self.explicitTargetID)
                    self.targetPopup.removeAllItems()
                    if self.targetPanes.count > 1 && self.explicitTargetID == nil { self.targetPopup.addItem(withTitle: "Select target pane…") }
                    for pane in self.targetPanes { self.targetPopup.addItem(withTitle: "\(pane.role ?? "Pane") · \(pane.title.isEmpty ? "pane \(pane.paneID)" : pane.title)"); self.targetPopup.lastItem?.representedObject = pane.paneID }
                    if let explicit = self.explicitTargetID, let index = self.targetPanes.firstIndex(where: { $0.paneID == explicit }) { self.targetPopup.selectItem(at: index) }
                    self.statusLabel.stringValue = "Ready. Review the prompt, then send explicitly."
                    self.updateSendButtonState()
                } catch { self.targetPanes = []; self.statusLabel.stringValue = error.localizedDescription; self.updateSendButtonState() }
            }
        } }
    }

    @objc private func sendPrompt(_ sender: Any?) {
        guard let document, let selection, selection.revision == revision, let originPaneID else { statusLabel.stringValue = "Select text again after the file reload."; return }
        // Re-read before sending. This catches a save that arrived between the
        // watcher event and the user's click and invalidates its selection.
        guard let current = try? String(contentsOf: document.url, encoding: .utf8) else { statusLabel.stringValue = "The file could not be read before sending."; sendButton.isEnabled = true; return }
        if current != document.text { reloadAfterExternalChange(); return }
        let prompt = promptView.string
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { statusLabel.stringValue = "Review text is empty."; return }
        isSending = true; updateSendButtonState(); statusLabel.stringValue = "Rechecking WezTerm panes…"
        service.listPanes { [weak self] result in DispatchQueue.main.async {
            guard let self else { return }
            guard self.document?.revision == document.revision, self.selection?.revision == selection.revision else { self.isSending = false; self.statusLabel.stringValue = "File reloaded; select text again."; self.updateSendButtonState(); return }
            switch result {
            case .failure(let error): self.isSending = false; self.statusLabel.stringValue = error.localizedDescription; self.updateSendButtonState()
            case .success(let panes):
                do {
                    let targets = try PaneTargetResolver.resolve(panes: panes, currentPaneID: originPaneID, explicitTargetID: self.explicitTargetID)
                    guard targets.count == 1 || self.explicitTargetID != nil else { self.isSending = false; self.statusLabel.stringValue = "Choose a target pane before sending."; self.updateSendButtonState(); return }
                    guard let target = targets.first else { throw PaneResolutionError.noTarget }
                    self.statusLabel.stringValue = "Sending to pane \(target.paneID)…"
                    self.service.send(text: prompt, to: target.paneID) { [weak self] result in DispatchQueue.main.async {
                        guard let self else { return }
                        self.isSending = false; self.updateSendButtonState()
                        switch result { case .success: self.statusLabel.stringValue = "Sent to pane \(target.paneID)."; case .failure(let error): self.statusLabel.stringValue = error.localizedDescription }
                    } }
                } catch { self.isSending = false; self.statusLabel.stringValue = error.localizedDescription; self.updateSendButtonState() }
            }
        } }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        if type == "ready" { webReady = true; renderCurrentDocument(); return }
        if type == "selectionCleared" { if let incomingRevision = body["revision"] as? Int, incomingRevision == revision { selection = nil; updateSendButtonState() }; return }
        guard type == "selection", let text = body["text"] as? String, let start = body["lineStart"] as? Int, let end = body["lineEnd"] as? Int, let incomingRevision = body["revision"] as? Int, incomingRevision == revision, let document else { return }
        selection = RenderedSelection(text: text, sourceRange: SourceRange(startLine: start, endLine: end), revision: document.revision)
        selectedLabel.stringValue = "Rendered selection · lines \(start)-\(end) · \(text.count) characters"
        updatePrompt()
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        let resourceRoot = viewerDirectoryURL?.standardizedFileURL.path ?? ""
        let localPath = url.standardizedFileURL.path
        if url.isFileURL && !resourceRoot.isEmpty && (localPath == resourceRoot || localPath.hasPrefix(resourceRoot + "/")) { decisionHandler(.allow); return }
        if action.navigationType == .linkActivated, ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") { NSWorkspace.shared.open(url); decisionHandler(.cancel); return }
        decisionHandler(.cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { webReady = true; renderCurrentDocument() }
    func controlTextDidChange(_ obj: Notification) { updatePrompt() }
    func textDidChange(_ notification: Notification) { updateSendButtonState() }
}
