import AppKit
import Carbon.HIToolbox
import UniformTypeIdentifiers
import WebKit

@main
@MainActor
struct QuickMarkviewMain {
    static func main() async {
        do {
            let options = try LaunchOptions()
            if options.showHelp { print(quickMarkviewUsage); return }
            let alreadyRunning = Bundle.main.bundleIdentifier.map { identifier in
                NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
                    .contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && $0.activationPolicy == .regular })
            } ?? false
            if options.launchThroughWorkspace || alreadyRunning {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.environment = ProcessInfo.processInfo.environment
                if let request = options.openRequest {
                    _ = try await NSWorkspace.shared.open([request.url], withApplicationAt: Bundle.main.bundleURL, configuration: configuration)
                } else {
                    if let pane = options.originPaneID { configuration.arguments += ["--pane", String(pane)] }
                    if let target = options.targetPaneID { configuration.arguments += ["--target-pane", String(target)] }
                    _ = try await NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration)
                }
                return
            }
            runApplication(options: options)
        } catch {
            FileHandle.standardError.write(Data("QuickMarkview: \(error.localizedDescription)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }

    private static func runApplication(options: LaunchOptions) {
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        let delegate = AppDelegate(options: options)
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private var controller: ViewerViewController!
    private let options: LaunchOptions
    private var pendingOpenRequest: OpenRequest?

    init(options: LaunchOptions) { self.options = options; super.init() }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)), forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenus()
        controller = ViewerViewController(options: options)
        window = NSWindow(contentViewController: controller)
        window.delegate = self
        window.title = "QuickMarkview"
        window.setContentSize(NSSize(width: 1200, height: 820))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        if let screen = NSScreen.main { window.setFrame(Self.launchFrame(in: screen.visibleFrame), display: false) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "q" {
                NSApp.terminate(nil)
                return nil
            }
            guard let self, let window = self.window, event.window === window else { return event }
            if self.controller.handleFileNavigationKey(event) { return nil }
            if self.controller?.isTextEditActive == true { return event }
            guard Self.closesViewer(characters: event.characters, firstResponder: window.firstResponder) else { return event }
            self.controller.hideZoomToast()
            window.orderOut(nil)
            return nil
        }
        if let pendingOpenRequest { self.pendingOpenRequest = nil; receive(pendingOpenRequest) }
    }

    @objc private func handleGetURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
        guard let value = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: value), let request = OpenRequest.parse(url: url) else { return }
        receive(request)
    }

    private func receive(_ request: OpenRequest) {
        guard let controller, let window else { pendingOpenRequest = request; return }
        controller.receive(request)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        if let request = OpenRequest.parse(url: url) { receive(request) }
        else if url.isFileURL {
            if let controller, let window {
                controller.receive(OpenRequest(fileURL: url))
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window.makeKeyAndOrderFront(nil)
        return true
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        (sender.contentViewController as? ViewerViewController)?.hideZoomToast()
        sender.orderOut(nil)
        return false
    }

    static func closesViewer(characters: String?, firstResponder: NSResponder?) -> Bool {
        characters == "q" && !(firstResponder is NSText)
    }

    static func launchFrame(in screen: NSRect) -> NSRect {
        NSRect(x: screen.minX, y: screen.minY, width: (screen.width * 2 / 3).rounded() - 5, height: screen.height)
    }

    private func installMenus() { NSApp.mainMenu = Self.mainMenu() }

    static func mainMenu() -> NSMenu {
        let menu = NSMenu()
        let appItem = NSMenuItem(); let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About QuickMarkview", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit QuickMarkview", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu; menu.addItem(appItem)

        let fileItem = NSMenuItem(); let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Open…", action: #selector(ViewerViewController.chooseFile(_:)), keyEquivalent: "o")
        fileMenu.addItem(withTitle: "Open Recent…", action: #selector(ViewerViewController.toggleRecentFiles(_:)), keyEquivalent: "e")
        fileItem.submenu = fileMenu; menu.addItem(fileItem)

        let editItem = NSMenuItem(); let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Find…", action: #selector(ViewerViewController.showFind(_:)), keyEquivalent: "f")
        editItem.submenu = editMenu; menu.addItem(editItem)

        let viewItem = NSMenuItem(); let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "Toggle Sidebar", action: #selector(ViewerViewController.toggleSidebar(_:)), keyEquivalent: "l")
        viewMenu.addItem(withTitle: "Go to Markdown File…", action: #selector(ViewerViewController.toggleFileFinder(_:)), keyEquivalent: "k")
        viewMenu.items.last?.keyEquivalentModifierMask = [.command]
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "Mark All Changes Reviewed (Space c c)", action: #selector(ViewerViewController.acknowledgeChanges(_:)), keyEquivalent: "")
        viewItem.submenu = viewMenu; menu.addItem(viewItem)
        return menu
    }

    private func showFatal(_ message: String) {
        let alert = NSAlert(); alert.messageText = "QuickMarkview"; alert.informativeText = message; alert.alertStyle = .critical; alert.runModal(); NSApp.terminate(nil)
    }
}

private enum TextEditError: Error {
    case conflict
}

@MainActor
final class ViewerViewController: NSViewController, WKNavigationDelegate, WKScriptMessageHandler, NSTextViewDelegate, NSSearchFieldDelegate {
    private let options: LaunchOptions
    private let service = WezTermService()
    private var watcher: FileWatcher?
    private var document: MarkdownDocument?
    private var selection: RenderedSelection?
    private var basket = ContextBasket()
    private var requestBasket = ContextBasket()
    private var zoomState = ZoomState()
    let zoomToast = ZoomToastView()
    private var zoomTopConstraint: NSLayoutConstraint?
    private var zoomFindConstraint: NSLayoutConstraint?
    private var revision: UInt64 = 0
    private var webReady = false
    private var queuedSource: String?
    private var queuedLine: Int?
    private var originPaneID: Int?
    private var targetPanes: [WezTermPane] = []
    private var explicitTargetID: Int?
    private var viewerDirectoryURL: URL?
    private var isSending = false
    private var alternate: (url: URL, line: Int)?
    private var finderGeneration = 0
    private var isShowingRecentFiles = false
    private let recentFiles = RecentFiles()
    private var isNavigatingFile = false
    private var isEditingText = false
    private var isSavingTextEdit = false
    private var pendingFileChange = false
    private let reviewSession = ChangeReviewSession()
    private var reviewTimer: Timer?
    private var reviewChanges: [ReviewChange] = []
    private var pendingReviewJump: Int?
    private let reviewButton = NSButton(title: "Changes 0 · Review All", target: nil, action: nil)
    private let fileEditQueue = DispatchQueue(label: "quickmarkview.fileedit", qos: .utility)
    var isTextEditActive: Bool { isEditingText }

    private let pathLabel = NSTextField(labelWithString: "No file open")
    private let lineLabel = NSTextField(labelWithString: "")
    private let targetPopup = NSPopUpButton()
    private let openButton = NSButton(title: "Open…", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: ViewerViewController.idleStatus)
    private let requestHint = NSTextField(labelWithString: "")
    private let requestScroll = NSTextView.scrollableTextView()
    private var requestView: NSTextView { requestScroll.documentView as! NSTextView }
    let requestPanel = NSVisualEffectView()
    private let fileFinder = FileFinderView(frame: .zero)
    let findField = NSSearchField()
    let findCount = NSTextField(labelWithString: "")
    let findBar = NSVisualEffectView()
    private var webView: WKWebView!

    private static let idleStatus = "v/V select · Space a y stash · Space a a request · q quit"
    private var readyStatus: String { stashStatus(Self.idleStatus) }
    private func stashStatus(_ message: String) -> String { basket.items.isEmpty ? message : "📎 \(basket.items.count) · \(message)" }

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
        fileFinder.isHidden = true
        fileFinder.onChoose = { [weak self] url in self?.chooseMarkdownFile(url) }
        fileFinder.onCancel = { [weak self] in self?.hideFileFinder() }
        let findBar = makeFindBar()
        for subview in [toolbar, page, panel, fileFinder, findBar, zoomToast] { subview.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(subview) }
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: root.topAnchor), toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor), toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor), toolbar.heightAnchor.constraint(equalToConstant: 46),
            page.topAnchor.constraint(equalTo: toolbar.bottomAnchor), page.leadingAnchor.constraint(equalTo: root.leadingAnchor), page.trailingAnchor.constraint(equalTo: root.trailingAnchor), page.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            panel.centerXAnchor.constraint(equalTo: root.centerXAnchor), panel.widthAnchor.constraint(equalTo: root.widthAnchor, multiplier: 0.7), panel.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -24), panel.heightAnchor.constraint(equalTo: root.heightAnchor, multiplier: 0.5),
            fileFinder.centerXAnchor.constraint(equalTo: root.centerXAnchor), fileFinder.centerYAnchor.constraint(equalTo: root.centerYAnchor, constant: 40), fileFinder.widthAnchor.constraint(equalTo: root.widthAnchor, multiplier: 0.6), fileFinder.heightAnchor.constraint(equalTo: root.heightAnchor, multiplier: 0.55),
            findBar.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 8), findBar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16), findField.widthAnchor.constraint(equalToConstant: 300)
        ])
        zoomTopConstraint = zoomToast.topAnchor.constraint(equalTo: page.topAnchor, constant: 16)
        zoomFindConstraint = zoomToast.topAnchor.constraint(equalTo: findBar.bottomAnchor, constant: 8)
        zoomTopConstraint?.isActive = true
        zoomToast.trailingAnchor.constraint(equalTo: page.trailingAnchor, constant: -16).isActive = true
        self.view = root
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if let url = options.fileURL { open(url: url, line: options.line) }
        view.window?.makeFirstResponder(webView)
        refreshTargets()
    }

    private func makeToolbar() -> NSView {
        reviewButton.target = self; reviewButton.action = #selector(acknowledgeChanges(_:))
        reviewButton.toolTip = "Mark all changes in all files reviewed (Space → c → c)"
        reviewButton.bezelStyle = .rounded
        openButton.target = self; openButton.action = #selector(chooseFile(_:)); openButton.bezelStyle = .rounded
        pathLabel.font = .systemFont(ofSize: 12); pathLabel.lineBreakMode = .byTruncatingMiddle; pathLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        lineLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular); lineLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 11); statusLabel.textColor = .secondaryLabelColor; statusLabel.lineBreakMode = .byTruncatingTail; statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        targetPopup.addItem(withTitle: "Target pane"); targetPopup.target = self; targetPopup.action = #selector(targetChanged(_:)); targetPopup.setContentHuggingPriority(.required, for: .horizontal)
        let stack = NSStackView(views: [openButton, pathLabel, lineLabel, statusLabel, reviewButton, targetPopup]); stack.orientation = .horizontal; stack.spacing = 8; stack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10); stack.translatesAutoresizingMaskIntoConstraints = false
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

    private func makeFindBar() -> NSView {
        findField.placeholderString = "Find · ↩ next · ⇧↩ previous · esc close"; findField.delegate = self
        findCount.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular); findCount.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [findField, findCount]); stack.spacing = 8; stack.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 10)
        findBar.material = .popover; findBar.state = .active; findBar.wantsLayer = true; findBar.layer?.cornerRadius = 8; findBar.isHidden = true
        findBar.addSubview(stack); _ = constrained(stack)
        return findBar
    }

    private func makeRequestPanel() -> NSView {
        requestHint.font = .systemFont(ofSize: 11); requestHint.textColor = .secondaryLabelColor
        requestView.delegate = self; requestView.isRichText = false; requestView.font = .monospacedSystemFont(ofSize: 13, weight: .regular); requestView.textContainerInset = NSSize(width: 6, height: 6)
        let stack = NSStackView(views: [requestHint, requestScroll]); stack.orientation = .vertical; stack.alignment = .width; stack.spacing = 6; stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 12, right: 12)
        requestPanel.material = .popover; requestPanel.state = .active; requestPanel.wantsLayer = true; requestPanel.layer?.cornerRadius = 10; requestPanel.isHidden = true
        requestPanel.addSubview(stack); _ = constrained(stack)
        return requestPanel
    }

    private func showRequestPanel() {
        requestBasket = basket
        if let document, let selection, selection.revision == revision {
            requestBasket.add(ContextItem(document: document, range: selection.sourceRange, text: selection.text), fileLines: document.lines)
        }
        guard !requestBasket.items.isEmpty else { statusLabel.stringValue = "Select text with v first."; return }
        presentRequest("")
        requestPanel.isHidden = false
        view.window?.makeFirstResponder(requestView)
    }

    private func presentRequest(_ request: String) {
        let items = requestBasket.items
        let prompt = PromptBuilder.build(items: items, request: request)
        let scope = items.count == 1 ? "Lines \(items[0].range.startLine)-\(items[0].range.endLine)" : "\(items.count) selections"
        requestHint.stringValue = "\(scope) · first line /btw for side chat · ⇧↩ send · esc cancel"
        requestView.string = prompt
        let cursor = request.isEmpty ? Self.requestCursor(in: prompt) : NSMaxRange((prompt as NSString).range(of: request))
        requestView.setSelectedRange(NSRange(location: cursor, length: 0))
        requestView.scrollRangeToVisible(requestView.selectedRange())
    }

    /// Re-reads every file in the request. If a save moved or dropped an item,
    /// the prompt is rebuilt around the typed request and nothing is sent.
    private func requestStillCurrent() -> Bool {
        var files: [URL: [String]] = [:]
        for url in Set(requestBasket.items.map(\.url)) {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { statusLabel.stringValue = "\(url.lastPathComponent) could not be read before sending."; return false }
            files[url] = MarkdownDocument(url: url, text: text).lines
        }
        let before = requestBasket.items
        for (url, lines) in files { requestBasket.reanchor(url: url, lines: lines); basket.reanchor(url: url, lines: lines) }
        if let document, let lines = files[document.url], lines != document.lines { reloadAfterExternalChange() }
        guard requestBasket.items != before else { return true }
        let changed = Set(before.filter { !requestBasket.items.contains($0) }.map(\.url.lastPathComponent)).sorted().joined(separator: ", ")
        guard !requestBasket.items.isEmpty else { hideRequestPanel(); statusLabel.stringValue = stashStatus("\(changed) changed; nothing left to send."); return false }
        if let request = PromptBuilder.request(in: requestView.string) { presentRequest(request) }
        statusLabel.stringValue = "\(changed) changed; review and press ⇧↩ again."
        return false
    }

    private func reconcileBasket() {
        guard let document else { return }
        let dropped = basket.reanchor(url: document.url, lines: document.lines)
        if dropped > 0 { statusLabel.stringValue = stashStatus("\(document.url.lastPathComponent) changed; \(dropped) stashed selection\(dropped == 1 ? "" : "s") dropped.") }
        pushStashMarks()
    }

    private func pushStashMarks() {
        let ranges = document.map { basket.ranges(in: $0.url).map { [$0.startLine, $0.endLine] } } ?? []
        let json = (try? String(data: JSONEncoder().encode(ranges), encoding: .utf8)) ?? "[]"
        webView?.evaluateJavaScript("window.quickMarkview.setStashMarks(\(json));", completionHandler: nil)
    }

    private func stashChanged(_ message: String) {
        pushStashMarks()
        statusLabel.stringValue = stashStatus(message)
    }

    static func requestCursor(in prompt: String) -> Int {
        let marker = (prompt as NSString).range(of: "Request:\n")
        return marker.location == NSNotFound ? 0 : NSMaxRange(marker)
    }

    private func hideRequestPanel() {
        requestPanel.isHidden = true
        view.window?.makeFirstResponder(webView)
    }

    @discardableResult
    func open(url: URL, line: Int?) -> Bool {
        let url = url.standardizedFileURL
        pendingReviewJump = nil
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            reviewSession.register(url: url, text: text)
            startReviewSession()
            webView.evaluateJavaScript("window.quickMarkview.cancelEdit();", completionHandler: nil)
            isEditingText = false
            revision &+= 1
            document = MarkdownDocument(url: url, text: text, revision: revision)
            selection = nil
            recentFiles.add(url)
            pathLabel.stringValue = url.path; lineLabel.stringValue = line.map { "line \($0)" } ?? ""
            statusLabel.stringValue = readyStatus
            reconcileBasket()
            watcher?.stop(); watcher = FileWatcher(fileURL: url) { [weak self] in DispatchQueue.main.async { self?.reloadAfterExternalChange() } }; watcher?.start()
            reviewChanges = []
            queuedSource = text; queuedLine = line; renderCurrentDocument()
            return true
        } catch { statusLabel.stringValue = "Could not open file: \(error.localizedDescription)"; return false }
    }

    func receive(_ request: OpenRequest) {
        originPaneID = request.paneID
        explicitTargetID = request.targetPaneID
        alternate = nil
        hideRequestPanel()
        _ = open(url: request.fileURL, line: request.line)
        refreshTargets()
    }

    private func reloadAfterExternalChange() {
        if isSavingTextEdit { pendingFileChange = true; return }
        guard let url = document?.url else { return }
        do {
            let diskText = try ChangeReviewSession.read(url.path)
            let text = diskText ?? ""
            pathLabel.stringValue = url.path + (diskText == nil ? " (deleted)" : "")
            guard text != document?.text else { return }
            if isEditingText {
                isEditingText = false
                webView.evaluateJavaScript("window.quickMarkview.cancelEdit();", completionHandler: nil)
            }
            revision &+= 1; document = MarkdownDocument(url: url, text: text, revision: revision)
            selection = nil
            statusLabel.stringValue = "External change loaded · [[ / ]] changes · Space c c review all"
            reconcileBasket()
            queuedSource = text; queuedLine = nil; renderCurrentDocument()
        } catch { statusLabel.stringValue = "File changed but could not be read: \(error.localizedDescription)" }
    }

    private func handleTextEdit(_ body: [String: Any]) {
        guard let document,
              let incomingRevision = body["revision"] as? Int,
              incomingRevision == Int(revision),
              let start = body["start"] as? Int,
              let end = body["end"] as? Int,
              let oldText = body["oldText"] as? String,
              let newText = body["newText"] as? String else {
            completeTextEdit(success: false, error: "Document changed. Reopen the editor and try again.")
            return
        }
        let originalText = document.text
        let source = originalText as NSString
        guard start >= 0, end >= start, end <= source.length,
              source.substring(with: NSRange(location: start, length: end - start)) == oldText else {
            completeTextEdit(success: false, error: "The source text no longer matches.")
            return
        }
        let updatedText = source.replacingCharacters(in: NSRange(location: start, length: end - start), with: newText)
        let url = document.url
        let editRevision = document.revision
        isSavingTextEdit = true
        statusLabel.stringValue = "Saving edit…"
        fileEditQueue.async { [weak self] in
            let result: Result<Void, Error>
            do {
                let fileManager = FileManager.default
                let temporaryURL = url.deletingLastPathComponent()
                    .appendingPathComponent(".\(url.lastPathComponent).quickmarkview-\(UUID().uuidString)")
                defer { try? fileManager.removeItem(at: temporaryURL) }
                try Data(updatedText.utf8).write(to: temporaryURL, options: .atomic)
                let diskText = try String(contentsOf: url, encoding: .utf8)
                guard diskText == originalText else { throw TextEditError.conflict }
                _ = try fileManager.replaceItemAt(url, withItemAt: temporaryURL, backupItemName: nil, options: [.usingNewMetadataOnly])
                result = .success(())
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.isSavingTextEdit = false
                guard self.document?.revision == editRevision else {
                    if self.pendingFileChange {
                        self.pendingFileChange = false
                        self.reloadAfterExternalChange()
                    }
                    return
                }
                if case .success = result, self.document?.revision == editRevision {
                    self.revision &+= 1
                    self.document = MarkdownDocument(url: url, text: updatedText, revision: self.revision)
                    self.selection = nil
                    self.isEditingText = false
                    self.statusLabel.stringValue = self.readyStatus
                    self.completeTextEdit(success: true, error: nil)
                    self.reconcileBasket()
                    self.refreshReview()
                } else {
                    let message: String
                    if case .failure(let error) = result {
                        message = error is TextEditError ? "File changed externally; edit was not saved." : "Could not save edit: \(error.localizedDescription)"
                    } else {
                        message = "Document changed before the edit finished saving."
                    }
                    self.completeTextEdit(success: false, error: message)
                    if self.pendingFileChange || message.hasPrefix("File changed externally") { self.reloadAfterExternalChange() }
                }
                if self.pendingFileChange {
                    self.pendingFileChange = false
                    self.reloadAfterExternalChange()
                }
            }
        }
    }

    private func completeTextEdit(success: Bool, error: String?) {
        if !success, let error { statusLabel.stringValue = error }
        let errorLiteral = error.flatMap { try? String(data: JSONEncoder().encode($0), encoding: .utf8) } ?? "null"
        webView.evaluateJavaScript("window.quickMarkview.finishEdit(\(success), \(revision), \(errorLiteral));", completionHandler: nil)
    }

    private func renderCurrentDocument() {
        guard webReady, let source = queuedSource else { return }
        // JSONEncoder safely handles a scalar String without interpolating
        // user content into executable JavaScript.
        let sourceLiteral = (try? String(data: JSONEncoder().encode(source), encoding: .utf8)) ?? "\"\""
        let lineLiteral = queuedLine.map(String.init) ?? "null"
        let languageLiteral: String
        if let document, case .code(let language) = DocumentKind.detect(url: document.url) {
            languageLiteral = (try? String(data: JSONEncoder().encode(language), encoding: .utf8)) ?? "null"
        } else {
            languageLiteral = "null"
        }
        webView.evaluateJavaScript("window.quickMarkview.setDocument(\(sourceLiteral), \(lineLiteral), \(revision), \(languageLiteral));", completionHandler: nil)
        queuedSource = nil
        refreshReview()
    }

    private func startReviewSession() {
        guard reviewTimer == nil else { return }
        reviewTimer = Timer.scheduledTimer(timeInterval: 1, target: self, selector: #selector(pollReview), userInfo: nil, repeats: true)
    }

    @objc private func pollReview() {
        reloadAfterExternalChange()
        refreshReview()
    }

    private func refreshReview() {
        guard webReady, let document else { return }
        do {
            let state = try reviewSession.snapshot()
            let baseline = state[document.url.path]?.baseline ?? document.text
            if let file = state[document.url.path], file.current == document.text {
                reviewChanges = file.changes
            } else { reviewChanges = ReviewChange.compare(baseline, document.text) }
            let count = state.values.reduce(0) { $0 + $1.changes.count }
            reviewButton.title = "Changes \(count) · Review All"
            let payload = String(data: try JSONEncoder().encode(reviewChanges), encoding: .utf8)!
            webView.evaluateJavaScript("window.quickMarkview.setReviewChanges(\(payload), \(revision));", completionHandler: nil)
        } catch { statusLabel.stringValue = "Could not load change review: \(error.localizedDescription)" }
    }

    @objc func acknowledgeChanges(_ sender: Any?) {
        guard !isSavingTextEdit else { statusLabel.stringValue = "Wait for the edit to finish saving."; return }
        do {
            try reviewSession.acknowledge()
            pollReview()
            statusLabel.stringValue = "All changes in all files marked reviewed."
        } catch { statusLabel.stringValue = "Could not mark changes reviewed: \(error.localizedDescription)" }
    }

    private func navigateReviewFile(direction: Int) {
        guard let document else { return }
        do {
            if let target = try reviewSession.nextFile(after: document.url.path, direction: direction) {
                showReviewFile(path: target.path, index: target.index)
                return
            }
            statusLabel.stringValue = direction > 0 ? "Last change reached." : "First change reached."
        } catch { statusLabel.stringValue = "Could not navigate changes: \(error.localizedDescription)" }
    }

    private func showReviewFile(path: String, index: Int) {
        let url = URL(fileURLWithPath: path)
        if document?.url != url {
            if FileManager.default.fileExists(atPath: path) {
                guard open(url: url, line: nil) else { return }
            } else {
                // Keep a deleted file reviewable without resurrecting it on disk.
                reviewSession.register(url: url, text: "")
                webView.evaluateJavaScript("window.quickMarkview.cancelEdit();", completionHandler: nil)
                isEditingText = false
                revision &+= 1
                document = MarkdownDocument(url: url, text: "", revision: revision)
                selection = nil
                pathLabel.stringValue = "\(path) (deleted)"
                lineLabel.stringValue = ""
                statusLabel.stringValue = "File deleted · select the deletion marker to review previous source."
                reconcileBasket()
                watcher?.stop(); watcher = FileWatcher(fileURL: url) { [weak self] in DispatchQueue.main.async { self?.reloadAfterExternalChange() } }; watcher?.start()
                queuedSource = ""; queuedLine = nil; renderCurrentDocument()
            }
        } else { pollReview() }
        pendingReviewJump = index
        view.window?.makeKeyAndOrderFront(nil)
        NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])
        view.window?.makeFirstResponder(webView)
        jumpToPendingReview()
    }

    private func jumpToPendingReview() {
        guard let index = pendingReviewJump else { return }
        webView.evaluateJavaScript("window.quickMarkview.jumpToReviewChange(\(index));", completionHandler: nil)
    }

    @objc func chooseFile(_ sender: Any?) {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.text, .plainText, .sourceCode, .init(filenameExtension: "md")!, .init(filenameExtension: "markdown")!]; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { open(url: url, line: nil) }
    }

    @objc private func targetChanged(_ sender: Any?) { explicitTargetID = targetPopup.selectedItem?.representedObject as? Int }

    @objc func toggleSidebar(_ sender: Any?) { webView.evaluateJavaScript("window.quickMarkview.toggleSidebar();", completionHandler: nil) }

    @objc func toggleFileFinder(_ sender: Any?) {
        if !fileFinder.isHidden && !isShowingRecentFiles {
            hideFileFinder()
            return
        }
        if !requestPanel.isHidden { hideRequestPanel() }
        guard let document else {
            statusLabel.stringValue = "Open a file first."
            return
        }
        let directory = document.url.deletingLastPathComponent().standardizedFileURL
        let root = ProjectRoot.find(from: directory) ?? directory
        finderGeneration &+= 1
        let generation = finderGeneration
        isShowingRecentFiles = false
        fileFinder.currentFileURL = document.url
        fileFinder.showIndexing(root: root)
        MarkdownFileIndex.list(root: root, runner: CommandRunner(timeout: 5)) { [weak self] paths in
            DispatchQueue.main.async {
                guard let self, self.finderGeneration == generation, !self.fileFinder.isHidden else { return }
                self.fileFinder.update(paths: paths)
                self.fileFinder.focusSearchField()
            }
        }
    }

    @objc func toggleRecentFiles(_ sender: Any?) {
        if !fileFinder.isHidden && isShowingRecentFiles {
            hideFileFinder()
            return
        }
        if !requestPanel.isHidden { hideRequestPanel() }
        finderGeneration &+= 1
        isShowingRecentFiles = true
        fileFinder.currentFileURL = document?.url
        fileFinder.showRecent(recentFiles.urls)
    }

    @objc func showFind(_ sender: Any?) {
        if !fileFinder.isHidden { hideFileFinder() }
        findBar.isHidden = false
        updateZoomToastPosition()
        view.window?.makeFirstResponder(findField)
        findField.currentEditor()?.selectAll(nil)
    }

    private func hideFind() {
        findBar.isHidden = true
        updateZoomToastPosition()
        view.window?.makeFirstResponder(webView)
    }

    func find(backwards: Bool) {
        let query = findField.stringValue
        guard !query.isEmpty else { return }
        let configuration = WKFindConfiguration(); configuration.backwards = backwards
        webView.find(query, configuration: configuration) { [weak self] _ in self?.updateFindCount() }
    }

    private func updateFindCount() {
        let query = findField.stringValue
        guard !query.isEmpty, let queryLiteral = try? String(data: JSONEncoder().encode(query), encoding: .utf8) else { findCount.stringValue = ""; return }
        webView.evaluateJavaScript("window.quickMarkview.findStatus(\(queryLiteral));") { [weak self] value, _ in
            guard let self, self.findField.stringValue == query, let status = value as? [String: Int],
                  let index = status["index"], let total = status["total"] else { return }
            self.findCount.stringValue = Self.findCountText(index: index, total: total)
        }
    }

    static func findCountText(index: Int, total: Int) -> String {
        if total == 0 { return "No matches" }
        return index > 0 ? "\(index)/\(total)" : "\(total) matches"
    }

    func controlTextDidChange(_ notification: Notification) {
        if notification.object as? NSSearchField === findField { updateFindCount() }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard control === findField else { return false }
        if selector == #selector(NSResponder.cancelOperation(_:)) { hideFind(); return true }
        guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
        find(backwards: NSApp.currentEvent?.modifierFlags.contains(.shift) == true); return true
    }

    private func hideFileFinder() {
        finderGeneration &+= 1
        fileFinder.isHidden = true
        view.window?.makeFirstResponder(webView)
    }

    private func chooseMarkdownFile(_ url: URL) {
        hideFileFinder()
        guard let currentURL = document?.url else { open(url: url, line: nil); return }
        webView.evaluateJavaScript("window.quickMarkview.visibleLine();") { [weak self] value, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                let line = (value as? NSNumber)?.intValue ?? 1
                if self.open(url: url, line: nil) { self.alternate = (currentURL, max(1, line)) }
                self.view.window?.makeFirstResponder(self.webView)
            }
        }
    }

    static func fileNavigationDirection(for event: NSEvent) -> MarkdownFileNavigation.Direction? {
        let modifiers = event.modifierFlags.intersection([.control, .command, .option, .shift])
        guard modifiers == .control else { return nil }
        switch Int(event.keyCode) {
        case kVK_LeftArrow: return .previous
        case kVK_RightArrow: return .next
        default: return nil
        }
    }

    /// Capture native arrow events before AppKit/WebKit can use them as cursor motions.
    func handleFileNavigationKey(_ event: NSEvent) -> Bool {
        guard let direction = Self.fileNavigationDirection(for: event), document != nil,
              !isEditingText, requestPanel.isHidden, fileFinder.isHidden,
              !(view.window?.firstResponder is NSTextView) else { return false }
        if isNavigatingFile { return true }
        let sourceRevision = revision
        isNavigatingFile = true
        webView.evaluateJavaScript("window.quickMarkview.visibleLine();") { [weak self] value, _ in
            guard let self else { return }
            self.isNavigatingFile = false
            guard self.revision == sourceRevision else { return }
            self.navigateMarkdownFile(direction: direction, fromLine: (value as? NSNumber)?.intValue ?? 1)
        }
        return true
    }

    private func navigateMarkdownFile(direction: MarkdownFileNavigation.Direction, fromLine: Int) {
        guard let document, !isNavigatingFile, !isEditingText, requestPanel.isHidden, fileFinder.isHidden else { return }
        let sourceRevision = revision
        let currentURL = document.url
        isNavigatingFile = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let target = MarkdownFileNavigation.adjacent(to: currentURL, direction: direction)
            DispatchQueue.main.async {
                guard let self else { return }
                self.isNavigatingFile = false
                guard self.revision == sourceRevision, !self.isEditingText,
                      self.requestPanel.isHidden, self.fileFinder.isHidden else { return }
                guard let target else {
                    self.statusLabel.stringValue = "No \(direction == .next ? "next" : "previous") Markdown file."
                    return
                }
                if self.open(url: target, line: nil) { self.alternate = (currentURL, max(1, fromLine)) }
            }
        }
    }

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
        guard !requestBasket.items.isEmpty, let originPaneID else { statusLabel.stringValue = "Select text again after the file reload."; return }
        guard requestStillCurrent() else { return }
        let prompt = requestView.string
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { statusLabel.stringValue = "Prompt is empty."; return }
        isSending = true; statusLabel.stringValue = "Rechecking WezTerm panes…"
        service.listPanes { [weak self] result in DispatchQueue.main.async {
            guard let self else { return }
            guard self.requestStillCurrent() else { self.isSending = false; return }
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
                        case .success:
                            self.basket.clear(); self.pushStashMarks()
                            self.statusLabel.stringValue = "Sent to pane \(target.paneID)."; self.hideRequestPanel()
                        case .failure(let error): self.statusLabel.stringValue = error.localizedDescription
                        }
                    } }
                } catch { self.isSending = false; self.statusLabel.stringValue = error.localizedDescription }
            }
        } }
    }

    func hideZoomToast() { zoomToast.dismiss() }

    private func updateZoomToastPosition() {
        zoomTopConstraint?.isActive = false
        zoomFindConstraint?.isActive = false
        if findBar.isHidden { zoomTopConstraint?.isActive = true }
        else { zoomFindConstraint?.isActive = true }
    }

    func handleZoomMessage(_ body: [String: Any]) {
        guard document != nil, body["revision"] as? Int == Int(revision),
              let rawAction = body["action"] as? String, let action = ZoomState.Action(rawValue: rawAction),
              !isEditingText, requestPanel.isHidden, fileFinder.isHidden,
              !(view.window?.firstResponder is NSTextView) else { return }
        guard zoomState.apply(action: action) else { return }
        webView.pageZoom = zoomState.pageZoom
        zoomToast.show(percent: zoomState.percent)
        webView.evaluateJavaScript("window.quickMarkview.refreshAfterZoom();", completionHandler: nil)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        if type == "zoom" { handleZoomMessage(body); return }
        if type == "ready" {
            webReady = true; renderCurrentDocument()
            if body["revision"] as? Int == Int(revision) { jumpToPendingReview(); pendingReviewJump = nil }
            return
        }
        if type == "acknowledgeChanges" {
            guard body["revision"] as? Int == Int(revision) else { return }
            acknowledgeChanges(nil); return
        }
        if type == "navigateReviewFile" {
            guard let incoming = body["revision"] as? Int, incoming == Int(revision), let direction = body["direction"] as? Int, abs(direction) == 1 else { return }
            navigateReviewFile(direction: direction); return
        }
        if type == "resolveImages" {
            guard let document, let incomingRevision = body["revision"] as? Int,
                  incomingRevision == Int(revision), let sources = body["sources"] as? [String] else { return }
            var imageData: [String: String] = [:]
            for source in sources {
                // Remote images stay blocked. Resolve only local paths beside the
                // Markdown file (or explicit file URLs) and pass bytes to WebKit.
                guard !source.isEmpty,
                      !source.hasPrefix("//"),
                      !source.lowercased().hasPrefix("http:"),
                      !source.lowercased().hasPrefix("https:"),
                      let imageURL = LinkResolver.resolve(href: source, relativeTo: document.url),
                      let data = try? Data(contentsOf: imageURL), !data.isEmpty else { continue }
                let ext = imageURL.pathExtension
                let mimeType = UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
                imageData[source] = "data:\(mimeType);base64,\(data.base64EncodedString())"
            }
            guard let json = try? String(data: JSONEncoder().encode(imageData), encoding: .utf8) else { return }
            webView.evaluateJavaScript("window.quickMarkview.setImageSources(\(incomingRevision), \(json));", completionHandler: nil)
            return
        }
        if type == "requestInput" { showRequestPanel(); return }
        if type == "stash" {
            guard let document, let selection, selection.revision == revision else { statusLabel.stringValue = "Select text with v first."; return }
            let range = selection.sourceRange
            let added = basket.add(ContextItem(document: document, range: range, text: selection.text), fileLines: document.lines)
            stashChanged(added ? "Stashed lines \(range.startLine)-\(range.endLine)." : "Already stashed.")
            return
        }
        if type == "unstash" {
            guard let document, let start = body["lineStart"] as? Int, let end = body["lineEnd"] as? Int else { return }
            let removed = basket.remove(url: document.url, overlapping: SourceRange(startLine: start, endLine: end))
            stashChanged(removed == 0 ? "Nothing stashed here." : "Removed \(removed) stashed selection\(removed == 1 ? "" : "s").")
            return
        }
        if type == "clearStash" { basket.clear(); stashChanged("Stash cleared."); return }
        if type == "editStarted" {
            guard let incomingRevision = body["revision"] as? Int, incomingRevision == Int(revision) else { return }
            isEditingText = true
            statusLabel.stringValue = "Editing · Enter save · Esc cancel"
            return
        }
        if type == "editFinished" {
            isEditingText = false
            if statusLabel.stringValue.hasPrefix("Editing") { statusLabel.stringValue = readyStatus }
            return
        }
        if type == "editUnavailable" { statusLabel.stringValue = "This text cannot be edited yet."; return }
        if type == "editText" { handleTextEdit(body); return }
        if type == "navigateFile" {
            guard let value = body["direction"] as? String, value == "next" || value == "previous" else { return }
            navigateMarkdownFile(direction: value == "next" ? .next : .previous, fromLine: body["fromLine"] as? Int ?? 1)
            return
        }
        if type == "openLink" {
            guard let href = body["href"] as? String, let document else { return }
            let fromLine = body["fromLine"] as? Int ?? 1
            guard let target = LinkResolver.resolve(href: href, relativeTo: document.url) else {
                statusLabel.stringValue = "Link target not found: \(href)"
                return
            }
            if open(url: target, line: nil) { alternate = (document.url, fromLine) }
            return
        }
        if type == "back" {
            guard let previous = alternate, let current = document else { return }
            let fromLine = body["fromLine"] as? Int ?? 1
            if open(url: previous.url, line: previous.line) { alternate = (current.url, fromLine) }
            return
        }
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
