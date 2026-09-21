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
        if let screen = NSScreen.main { window.setFrame(Self.launchFrame(in: screen.visibleFrame), display: false) }
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

    static func launchFrame(in screen: NSRect) -> NSRect {
        NSRect(x: screen.minX, y: screen.minY, width: (screen.width * 2 / 3).rounded(), height: screen.height)
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
final class ViewerViewController: NSViewController, WKNavigationDelegate, WKScriptMessageHandler, NSTextViewDelegate {
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

    private let pathLabel = NSTextField(labelWithString: "No file open")
    private let lineLabel = NSTextField(labelWithString: "")
    private let targetPopup = NSPopUpButton()
    private let openButton = NSButton(title: "Open…", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: ViewerViewController.idleStatus)
    private let requestHint = NSTextField(labelWithString: "")
    private let requestScroll = NSTextView.scrollableTextView()
    private var requestView: NSTextView { requestScroll.documentView as! NSTextView }
    let requestPanel = NSVisualEffectView()
    private var webView: WKWebView!

    private static let idleStatus = "v select · Space a a request · q quit"

    init(options: LaunchOptions) {
        self.options = options
        self.originPaneID = options.originPaneID ?? Int(ProcessInfo.processInfo.environment["WEZTERM_PANE"] ?? "")
        self.explicitTargetID = options.targetPaneID
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let root = NSView(); root.wantsLayer = true
        let toolbar = makeToolbar(), page = makeWebView(), panel = makeRequestPanel()
        for subview in [toolbar, page, panel] { subview.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(subview) }
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: root.topAnchor), toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor), toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor), toolbar.heightAnchor.constraint(equalToConstant: 46),
            page.topAnchor.constraint(equalTo: toolbar.bottomAnchor), page.leadingAnchor.constraint(equalTo: root.leadingAnchor), page.trailingAnchor.constraint(equalTo: root.trailingAnchor), page.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            panel.centerXAnchor.constraint(equalTo: root.centerXAnchor), panel.widthAnchor.constraint(equalTo: root.widthAnchor, multiplier: 0.7), panel.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -24), panel.heightAnchor.constraint(equalTo: root.heightAnchor, multiplier: 0.5)
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

    private func makeToolbar() -> NSView {
        openButton.target = self; openButton.action = #selector(chooseFile(_:)); openButton.bezelStyle = .rounded
        pathLabel.font = .systemFont(ofSize: 12); pathLabel.lineBreakMode = .byTruncatingMiddle; pathLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        lineLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular); lineLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 11); statusLabel.textColor = .secondaryLabelColor; statusLabel.lineBreakMode = .byTruncatingTail; statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        targetPopup.addItem(withTitle: "Target pane"); targetPopup.target = self; targetPopup.action = #selector(targetChanged(_:)); targetPopup.setContentHuggingPriority(.required, for: .horizontal)
        let stack = NSStackView(views: [openButton, pathLabel, lineLabel, statusLabel, targetPopup]); stack.orientation = .horizontal; stack.spacing = 8; stack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10); stack.translatesAutoresizingMaskIntoConstraints = false
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

    private func makeRequestPanel() -> NSView {
        requestHint.font = .systemFont(ofSize: 11); requestHint.textColor = .secondaryLabelColor
        requestView.delegate = self; requestView.isRichText = false; requestView.font = .monospacedSystemFont(ofSize: 13, weight: .regular); requestView.textContainerInset = NSSize(width: 6, height: 6)
        let stack = NSStackView(views: [requestHint, requestScroll]); stack.orientation = .vertical; stack.alignment = .width; stack.spacing = 6; stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 12, right: 12)
        requestPanel.material = .popover; requestPanel.state = .active; requestPanel.wantsLayer = true; requestPanel.layer?.cornerRadius = 10; requestPanel.isHidden = true
        requestPanel.addSubview(stack); _ = constrained(stack)
        return requestPanel
    }

    private func showRequestPanel() {
        guard let document, let selection, selection.revision == revision else { statusLabel.stringValue = "Select text with v first."; return }
        let prompt = PromptBuilder.build(context: document, range: selection.sourceRange, request: "", selectedText: selection.text)
        requestHint.stringValue = "Lines \(selection.sourceRange.startLine)-\(selection.sourceRange.endLine) · first line /btw for side chat · ⇧↩ send · esc cancel"
        requestView.string = prompt
        requestView.setSelectedRange(NSRange(location: Self.requestCursor(in: prompt), length: 0))
        requestView.scrollRangeToVisible(requestView.selectedRange())
        requestPanel.isHidden = false
        view.window?.makeFirstResponder(requestView)
    }

    static func requestCursor(in prompt: String) -> Int {
        let marker = (prompt as NSString).range(of: "Request:\n")
        return marker.location == NSNotFound ? 0 : NSMaxRange(marker)
    }

    private func hideRequestPanel() {
        requestPanel.isHidden = true
        view.window?.makeFirstResponder(webView)
    }

    func open(url: URL, line: Int?) {
        let url = url.standardizedFileURL
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            revision &+= 1
            document = MarkdownDocument(url: url, text: text, revision: revision)
            selection = nil
            pathLabel.stringValue = url.path; lineLabel.stringValue = line.map { "line \($0)" } ?? ""
            statusLabel.stringValue = Self.idleStatus
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
            selection = nil
            statusLabel.stringValue = "Selection cleared after file reload. Select text again."
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

    @objc private func targetChanged(_ sender: Any?) { explicitTargetID = targetPopup.selectedItem?.representedObject as? Int }

    private func refreshTargets() {
        guard let originPaneID else { statusLabel.stringValue = "WEZTERM_PANE is not set; open from WezTerm or pass --pane."; return }
        service.listPanes { [weak self] result in DispatchQueue.main.async {
            guard let self else { return }
            switch result {
            case .failure(let error): self.targetPanes = []; self.statusLabel.stringValue = error.localizedDescription
            case .success(let panes):
                do {
                    self.targetPanes = try PaneTargetResolver.resolve(panes: panes, currentPaneID: originPaneID, explicitTargetID: self.explicitTargetID)
                    self.targetPopup.removeAllItems()
                    if self.targetPanes.count > 1 && self.explicitTargetID == nil { self.targetPopup.addItem(withTitle: "Select target pane…") }
                    for pane in self.targetPanes { self.targetPopup.addItem(withTitle: "\(pane.role ?? "Pane") · \(pane.title.isEmpty ? "pane \(pane.paneID)" : pane.title)"); self.targetPopup.lastItem?.representedObject = pane.paneID }
                    if let explicit = self.explicitTargetID, let index = self.targetPanes.firstIndex(where: { $0.paneID == explicit }) { self.targetPopup.selectItem(at: index) }
                } catch { self.targetPanes = []; self.statusLabel.stringValue = error.localizedDescription }
            }
        } }
    }

    private func sendPrompt() {
        guard !isSending else { return }
        guard let document, let selection, selection.revision == revision, let originPaneID else { statusLabel.stringValue = "Select text again after the file reload."; return }
        // Re-read before sending. This catches a save that arrived between the
        // watcher event and the user's keystroke and invalidates its selection.
        guard let current = try? String(contentsOf: document.url, encoding: .utf8) else { statusLabel.stringValue = "The file could not be read before sending."; return }
        if current != document.text { reloadAfterExternalChange(); return }
        let prompt = requestView.string
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { statusLabel.stringValue = "Prompt is empty."; return }
        isSending = true; statusLabel.stringValue = "Rechecking WezTerm panes…"
        service.listPanes { [weak self] result in DispatchQueue.main.async {
            guard let self else { return }
            guard self.document?.revision == document.revision, self.selection?.revision == selection.revision else { self.isSending = false; self.statusLabel.stringValue = "File reloaded; select text again."; return }
            switch result {
            case .failure(let error): self.isSending = false; self.statusLabel.stringValue = error.localizedDescription
            case .success(let panes):
                do {
                    let targets = try PaneTargetResolver.resolve(panes: panes, currentPaneID: originPaneID, explicitTargetID: self.explicitTargetID)
                    guard targets.count == 1 || self.explicitTargetID != nil else { self.isSending = false; self.statusLabel.stringValue = "Choose a target pane before sending."; return }
                    guard let target = targets.first else { throw PaneResolutionError.noTarget }
                    self.statusLabel.stringValue = "Sending to pane \(target.paneID)…"
                    self.service.send(text: prompt, to: target.paneID) { [weak self] result in DispatchQueue.main.async {
                        guard let self else { return }
                        self.isSending = false
                        switch result {
                        case .success: self.statusLabel.stringValue = "Sent to pane \(target.paneID)."; self.hideRequestPanel()
                        case .failure(let error): self.statusLabel.stringValue = error.localizedDescription
                        }
                    } }
                } catch { self.isSending = false; self.statusLabel.stringValue = error.localizedDescription }
            }
        } }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        if type == "ready" { webReady = true; renderCurrentDocument(); return }
        if type == "requestInput" { showRequestPanel(); return }
        guard requestPanel.isHidden else { return }
        if type == "selectionCleared" { if let incomingRevision = body["revision"] as? Int, incomingRevision == revision { selection = nil }; return }
        guard type == "selection", let text = body["text"] as? String, let start = body["lineStart"] as? Int, let end = body["lineEnd"] as? Int, let incomingRevision = body["revision"] as? Int, incomingRevision == revision, let document else { return }
        selection = RenderedSelection(text: text, sourceRange: SourceRange(startLine: start, endLine: end), revision: document.revision)
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

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) { hideRequestPanel(); return true }
        guard selector == #selector(NSResponder.insertNewline(_:)), NSApp.currentEvent?.modifierFlags.contains(.shift) == true else { return false }
        sendPrompt(); return true
    }
}
