import Cocoa
import USBDeviceSwift
import UniformTypeIdentifiers

extension Notification.Name {
    static let ProgressUpdate = Notification.Name("ProgressUpdate")
    static let MenubarPush = Notification.Name("MenubarPush")
    static let MenubarOpen = Notification.Name("MenubarOpen")
}

protocol PayloadDropDelegate: AnyObject {
    func didAcceptDroppedPayload(url: URL)
}

class PayloadDropView: NSView {
    weak var delegate: PayloadDropDelegate?
    
    var isHighlighted: Bool = false {
        didSet {
            needsDisplay = true
        }
    }
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }
    
    private func commonInit() {
        wantsLayer = true
        layer?.cornerRadius = 8
        registerForDraggedTypes([.fileURL])
    }
    
    override func updateLayer() {
        super.updateLayer()
        if isHighlighted {
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.10).cgColor
            layer?.borderColor = NSColor.controlAccentColor.cgColor
            layer?.borderWidth = 2.0
        } else {
            layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.4).cgColor
            layer?.borderColor = NSColor.separatorColor.cgColor
            layer?.borderWidth = 1.0
        }
    }
    
    override var wantsUpdateLayer: Bool {
        return true
    }
    
    private func extractBinURL(from sender: NSDraggingInfo) -> URL? {
        guard let items = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
              let url = items.first,
              url.pathExtension.lowercased() == "bin" else {
            return nil
        }
        return url
    }
    
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if extractBinURL(from: sender) != nil {
            isHighlighted = true
            return .copy
        }
        return []
    }
    
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        return extractBinURL(from: sender) != nil ? .copy : []
    }
    
    override func draggingExited(_ sender: NSDraggingInfo?) {
        isHighlighted = false
    }
    
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isHighlighted = false
        guard let url = extractBinURL(from: sender) else { return false }
        delegate?.didAcceptDroppedPayload(url: url)
        return true
    }
}

enum DeviceConnectionStatus {
    case disconnected
    case rcmConnected
    case standardConnected
    case payloadLaunched(NXPayload)
}

class ViewController: NSViewController, PayloadDropDelegate {
    
    // Storyboard outlets kept for compatibility
    @IBOutlet var consoleOutputBox: NSTextView!
    @IBOutlet weak var statusImage: NSImageView!
    @IBOutlet var progressBar: NSProgressIndicator!
    @IBOutlet var cbPayloadPaths: NSComboBox!
    @IBOutlet var btPush: NSButton!
    @IBOutlet var lbUpdate: NSTextField!
    @IBOutlet var chbAutopush: NSButton!
    
    // Modern UI Elements
    private let statusCardView = NSBox()
    private let customStatusImageView = NSImageView()
    private let statusTitleLabel = NSTextField(labelWithString: "Waiting for RCM Device")
    private let statusSubtitleLabel = NSTextField(labelWithString: "Connect your Nintendo Switch via USB in RCM mode.")
    
    private let payloadDropView = PayloadDropView()
    private let payloadIconView = NSImageView()
    private let payloadNameLabel = NSTextField(labelWithString: "No payload selected")
    private let payloadDetailLabel = NSTextField(labelWithString: "Drag a .bin file here or click Browse.")
    private let payloadTypeBadge = NSTextField(labelWithString: "")
    private let browseButton = NSButton(title: "Browse...", target: nil, action: nil)
    private let recentPopUp = NSPopUpButton(frame: .zero, pullsDown: true)
    
    private let customProgressBar = NSProgressIndicator()
    private let injectButton = NSButton(title: "Inject Payload", target: nil, action: nil)
    private let autopushToggle = NSButton(checkboxWithTitle: "Inject automatically on connect", target: nil, action: nil)
    
    private let logSectionBox = NSBox()
    private let logDisclosureButton = NSButton(title: "Show Activity Log", target: nil, action: nil)
    private let clearLogButton = NSButton(title: "Clear", target: nil, action: nil)
    private let logScrollView = NSScrollView()
    private var logHeightConstraint: NSLayoutConstraint?
    private var isLogExpanded = false
    
    private let updateBannerBox = NSBox()
    private let updateBannerLabel = NSTextField(labelWithString: "")
    private var updateURL: String?
    
    // State
    var connectedDevice: TegraDevice?
    var devices: [TegraDevice] = []
    var forceAllowPush = false
    var canPush = false
    var doAutopush = false
    private var isInjecting = false
    
    private var selectedPayloadURL: URL?
    private var inferredPayloadType: NXPayload = .generic
    private let recentPathsKey = "RecentPayloadPaths"
    private let autopushKey = "AutoPushOn"
    private let maxRecentPaths = 5
    
    private let ver = "1.0.0"
    private let crystalrcmGh = "https://api.github.com/repos/prayerie/CrystalRCM/releases/latest"
    
    // MARK: - Lifecycle
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        setupNotificationObservers()
        setupModernUI()
        
        NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.flagsChanged(with: event)
            return event
        }
        
        loadPreferences()
        updateConnectionStatus(.disconnected)
        updatePushState()
        checkForUpdates()
    }
    
    override func viewWillDisappear() {
        super.viewWillDisappear()
        // Standard window close lifecycle; exit(0) removed to allow clean AppKit teardown.
    }
    
    // MARK: - Notifications
    
    private func setupNotificationObservers() {
        NotificationCenter.default.addObserver(self, selector: #selector(self.usbConnected), name: .USBDeviceConnected, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(self.usbDisconnected), name: .USBDeviceDisconnected, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(self.onProgressUpdate), name: .ProgressUpdate, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(self.onPayloadTypeInferred), name: .PayloadTypeDetected, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(self.onMenubarPayloadPress), name: .MenubarPush, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(self.onMenubarOpen), name: .MenubarOpen, object: nil)
    }
    
    // MARK: - UI Construction
    
    private func setupModernUI() {
        // Clear storyboard prototype subviews to build a clean Auto Layout hierarchy
        view.subviews.forEach { $0.removeFromSuperview() }
        view.wantsLayer = true
        
        // 1. Status Card
        statusCardView.boxType = .custom
        statusCardView.borderWidth = 1
        statusCardView.borderColor = NSColor.separatorColor
        statusCardView.cornerRadius = 8
        statusCardView.fillColor = NSColor.controlBackgroundColor.withAlphaComponent(0.6)
        statusCardView.translatesAutoresizingMaskIntoConstraints = false
        
        customStatusImageView.imageScaling = .scaleProportionallyUpOrDown
        customStatusImageView.image = WAITING
        customStatusImageView.translatesAutoresizingMaskIntoConstraints = false
        
        statusTitleLabel.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        statusTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        
        statusSubtitleLabel.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        statusSubtitleLabel.textColor = NSColor.secondaryLabelColor
        statusSubtitleLabel.cell?.wraps = true
        statusSubtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        
        statusCardView.addSubview(customStatusImageView)
        statusCardView.addSubview(statusTitleLabel)
        statusCardView.addSubview(statusSubtitleLabel)
        
        // 2. Payload Drop Card
        payloadDropView.delegate = self
        payloadDropView.translatesAutoresizingMaskIntoConstraints = false
        if #available(macOS 12.0, *), let uti = UTType(filenameExtension: "bin") {
            payloadIconView.image = NSWorkspace.shared.icon(for: uti)
        } else {
            payloadIconView.image = NSWorkspace.shared.icon(forFileType: "bin")
        }
        payloadIconView.imageScaling = .scaleProportionallyUpOrDown
        payloadIconView.translatesAutoresizingMaskIntoConstraints = false
        
        payloadNameLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        payloadNameLabel.lineBreakMode = .byTruncatingMiddle
        payloadNameLabel.translatesAutoresizingMaskIntoConstraints = false
        
        payloadDetailLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        payloadDetailLabel.textColor = NSColor.secondaryLabelColor
        payloadDetailLabel.translatesAutoresizingMaskIntoConstraints = false
        
        payloadTypeBadge.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        payloadTypeBadge.textColor = NSColor.controlAccentColor
        payloadTypeBadge.isHidden = true
        payloadTypeBadge.translatesAutoresizingMaskIntoConstraints = false
        
        browseButton.target = self
        browseButton.action = #selector(onPayloadPress(_:))
        browseButton.bezelStyle = .rounded
        browseButton.keyEquivalent = "o"
        browseButton.keyEquivalentModifierMask = .command
        browseButton.translatesAutoresizingMaskIntoConstraints = false
        
        recentPopUp.target = self
        recentPopUp.action = #selector(onRecentPayloadSelected(_:))
        recentPopUp.bezelStyle = .rounded
        recentPopUp.translatesAutoresizingMaskIntoConstraints = false
        
        payloadDropView.addSubview(payloadIconView)
        payloadDropView.addSubview(payloadNameLabel)
        payloadDropView.addSubview(payloadDetailLabel)
        payloadDropView.addSubview(payloadTypeBadge)
        payloadDropView.addSubview(browseButton)
        payloadDropView.addSubview(recentPopUp)
        
        // 3. Progress Bar
        customProgressBar.style = .bar
        customProgressBar.isIndeterminate = false
        customProgressBar.minValue = 0.0
        customProgressBar.maxValue = 100.0
        customProgressBar.doubleValue = 0.0
        customProgressBar.isHidden = true
        customProgressBar.translatesAutoresizingMaskIntoConstraints = false
        
        // 4. Action Row
        injectButton.target = self
        injectButton.action = #selector(onPushPress(_:))
        injectButton.bezelStyle = .rounded
        injectButton.controlSize = .regular
        injectButton.keyEquivalent = "\r"
        injectButton.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        injectButton.translatesAutoresizingMaskIntoConstraints = false
        
        autopushToggle.target = self
        autopushToggle.action = #selector(onAutopushToggle(_:))
        autopushToggle.font = NSFont.systemFont(ofSize: 12)
        autopushToggle.translatesAutoresizingMaskIntoConstraints = false
        
        // 5. Activity Log Section
        logSectionBox.boxType = .custom
        logSectionBox.borderWidth = 0
        logSectionBox.fillColor = .clear
        logSectionBox.translatesAutoresizingMaskIntoConstraints = false
        
        logDisclosureButton.isBordered = false
        logDisclosureButton.title = "▸ Show Activity Log"
        logDisclosureButton.target = self
        logDisclosureButton.action = #selector(toggleLogExpansion)
        logDisclosureButton.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        logDisclosureButton.contentTintColor = NSColor.secondaryLabelColor
        logDisclosureButton.translatesAutoresizingMaskIntoConstraints = false
        
        clearLogButton.isBordered = false
        clearLogButton.title = "Clear"
        clearLogButton.target = self
        clearLogButton.action = #selector(clearLog)
        clearLogButton.font = NSFont.systemFont(ofSize: 11)
        clearLogButton.contentTintColor = NSColor.secondaryLabelColor
        clearLogButton.isHidden = true
        clearLogButton.translatesAutoresizingMaskIntoConstraints = false
        
        logScrollView.hasVerticalScroller = true
        logScrollView.hasHorizontalScroller = false
        logScrollView.autohidesScrollers = true
        logScrollView.borderType = .bezelBorder
        logScrollView.translatesAutoresizingMaskIntoConstraints = false
        
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.autoresizingMask = [.width]
        logScrollView.documentView = textView
        consoleOutputBox = textView
        
        logSectionBox.addSubview(logDisclosureButton)
        logSectionBox.addSubview(clearLogButton)
        logSectionBox.addSubview(logScrollView)
        
        // 6. Update Banner
        updateBannerBox.boxType = .custom
        updateBannerBox.borderWidth = 1
        updateBannerBox.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.4)
        updateBannerBox.cornerRadius = 6
        updateBannerBox.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.08)
        updateBannerBox.isHidden = true
        updateBannerBox.translatesAutoresizingMaskIntoConstraints = false
        
        updateBannerLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        updateBannerLabel.isSelectable = true
        updateBannerLabel.translatesAutoresizingMaskIntoConstraints = false
        updateBannerBox.addSubview(updateBannerLabel)
        
        // Add all components to view
        view.addSubview(statusCardView)
        view.addSubview(payloadDropView)
        view.addSubview(customProgressBar)
        view.addSubview(injectButton)
        view.addSubview(autopushToggle)
        view.addSubview(updateBannerBox)
        view.addSubview(logSectionBox)
        
        // Setup Constraints
        logHeightConstraint = logScrollView.heightAnchor.constraint(equalToConstant: 0)
        logScrollView.isHidden = true
        
        NSLayoutConstraint.activate([
            // Status Card
            statusCardView.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            statusCardView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            statusCardView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            statusCardView.heightAnchor.constraint(equalToConstant: 72),
            
            customStatusImageView.leadingAnchor.constraint(equalTo: statusCardView.leadingAnchor, constant: 14),
            customStatusImageView.centerYAnchor.constraint(equalTo: statusCardView.centerYAnchor),
            customStatusImageView.widthAnchor.constraint(equalToConstant: 44),
            customStatusImageView.heightAnchor.constraint(equalToConstant: 44),
            
            statusTitleLabel.topAnchor.constraint(equalTo: statusCardView.topAnchor, constant: 14),
            statusTitleLabel.leadingAnchor.constraint(equalTo: customStatusImageView.trailingAnchor, constant: 14),
            statusTitleLabel.trailingAnchor.constraint(equalTo: statusCardView.trailingAnchor, constant: -14),
            
            statusSubtitleLabel.topAnchor.constraint(equalTo: statusTitleLabel.bottomAnchor, constant: 4),
            statusSubtitleLabel.leadingAnchor.constraint(equalTo: customStatusImageView.trailingAnchor, constant: 14),
            statusSubtitleLabel.trailingAnchor.constraint(equalTo: statusCardView.trailingAnchor, constant: -14),
            
            // Payload Drop Card
            payloadDropView.topAnchor.constraint(equalTo: statusCardView.bottomAnchor, constant: 12),
            payloadDropView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            payloadDropView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            payloadDropView.heightAnchor.constraint(equalToConstant: 68),
            
            payloadIconView.leadingAnchor.constraint(equalTo: payloadDropView.leadingAnchor, constant: 14),
            payloadIconView.centerYAnchor.constraint(equalTo: payloadDropView.centerYAnchor),
            payloadIconView.widthAnchor.constraint(equalToConstant: 36),
            payloadIconView.heightAnchor.constraint(equalToConstant: 36),
            
            payloadNameLabel.topAnchor.constraint(equalTo: payloadDropView.topAnchor, constant: 13),
            payloadNameLabel.leadingAnchor.constraint(equalTo: payloadIconView.trailingAnchor, constant: 12),
            payloadNameLabel.trailingAnchor.constraint(lessThanOrEqualTo: browseButton.leadingAnchor, constant: -12),
            
            payloadDetailLabel.topAnchor.constraint(equalTo: payloadNameLabel.bottomAnchor, constant: 3),
            payloadDetailLabel.leadingAnchor.constraint(equalTo: payloadIconView.trailingAnchor, constant: 12),
            
            payloadTypeBadge.centerYAnchor.constraint(equalTo: payloadDetailLabel.centerYAnchor),
            payloadTypeBadge.leadingAnchor.constraint(equalTo: payloadDetailLabel.trailingAnchor, constant: 8),
            payloadTypeBadge.trailingAnchor.constraint(lessThanOrEqualTo: browseButton.leadingAnchor, constant: -8),
            
            browseButton.trailingAnchor.constraint(equalTo: recentPopUp.leadingAnchor, constant: -6),
            browseButton.centerYAnchor.constraint(equalTo: payloadDropView.centerYAnchor),
            browseButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 80),
            
            recentPopUp.trailingAnchor.constraint(equalTo: payloadDropView.trailingAnchor, constant: -12),
            recentPopUp.centerYAnchor.constraint(equalTo: payloadDropView.centerYAnchor),
            recentPopUp.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
            
            // Progress Bar
            customProgressBar.topAnchor.constraint(equalTo: payloadDropView.bottomAnchor, constant: 8),
            customProgressBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            customProgressBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            customProgressBar.heightAnchor.constraint(equalToConstant: 6),
            
            // Action Row
            injectButton.topAnchor.constraint(equalTo: customProgressBar.bottomAnchor, constant: 8),
            injectButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            injectButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 140),
            
            autopushToggle.centerYAnchor.constraint(equalTo: injectButton.centerYAnchor),
            autopushToggle.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            autopushToggle.trailingAnchor.constraint(lessThanOrEqualTo: injectButton.leadingAnchor, constant: -12),
            
            // Update Banner
            updateBannerBox.topAnchor.constraint(equalTo: injectButton.bottomAnchor, constant: 10),
            updateBannerBox.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            updateBannerBox.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            updateBannerBox.heightAnchor.constraint(equalToConstant: 28),
            
            updateBannerLabel.leadingAnchor.constraint(equalTo: updateBannerBox.leadingAnchor, constant: 10),
            updateBannerLabel.centerYAnchor.constraint(equalTo: updateBannerBox.centerYAnchor),
            
            // Activity Log Section
            logSectionBox.topAnchor.constraint(equalTo: updateBannerBox.bottomAnchor, constant: 6),
            logSectionBox.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            logSectionBox.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            logSectionBox.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),
            
            logDisclosureButton.topAnchor.constraint(equalTo: logSectionBox.topAnchor),
            logDisclosureButton.leadingAnchor.constraint(equalTo: logSectionBox.leadingAnchor),
            
            clearLogButton.topAnchor.constraint(equalTo: logSectionBox.topAnchor),
            clearLogButton.trailingAnchor.constraint(equalTo: logSectionBox.trailingAnchor),
            
            logScrollView.topAnchor.constraint(equalTo: logDisclosureButton.bottomAnchor, constant: 6),
            logScrollView.leadingAnchor.constraint(equalTo: logSectionBox.leadingAnchor),
            logScrollView.trailingAnchor.constraint(equalTo: logSectionBox.trailingAnchor),
            logScrollView.bottomAnchor.constraint(equalTo: logSectionBox.bottomAnchor),
            logHeightConstraint!
        ])
    }
    
    // MARK: - State Management
    
    private func loadPreferences() {
        let apOn = UserDefaults.standard.integer(forKey: autopushKey)
        autopushToggle.state = apOn == 1 ? .on : .off
        doAutopush = apOn == 1
        
        refreshRecentPopUp()
        
        if let paths = UserDefaults.standard.array(forKey: recentPathsKey) as? [String],
           let firstValidPath = paths.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            loadPayload(url: URL(fileURLWithPath: firstValidPath))
        }
    }
    
    private func updateConnectionStatus(_ status: DeviceConnectionStatus) {
        DispatchQueue.main.async {
            switch status {
            case .disconnected:
                self.customStatusImageView.image = WAITING
                self.statusTitleLabel.stringValue = "Waiting for RCM Device"
                self.statusSubtitleLabel.stringValue = "Connect your Nintendo Switch via USB in RCM mode."
                self.statusSubtitleLabel.textColor = NSColor.secondaryLabelColor
            case .rcmConnected:
                self.customStatusImageView.image = READY
                self.statusTitleLabel.stringValue = "Nintendo Switch in RCM"
                self.statusSubtitleLabel.stringValue = "Tegra X1 APX connected and ready for injection."
                self.statusSubtitleLabel.textColor = NSColor.systemGreen
            case .standardConnected:
                self.customStatusImageView.image = NSImage(named: NSImage.cautionName)
                self.statusTitleLabel.stringValue = "Console in Standard Mode (Not RCM)"
                self.statusSubtitleLabel.stringValue = "Turn off console, attach RCM jig to right rail, then hold Volume Up and press Power."
                self.statusSubtitleLabel.textColor = NSColor.systemOrange
            case .payloadLaunched(let payload):
                self.customStatusImageView.image = payload.successImage ?? READY
                self.statusTitleLabel.stringValue = "Payload Injected"
                self.statusSubtitleLabel.stringValue = "\(payload.title) launched on console."
                self.statusSubtitleLabel.textColor = NSColor.systemGreen
            }
        }
    }
    
    private func updatePushState() {
        DispatchQueue.main.async {
            if self.isInjecting {
                self.injectButton.isEnabled = false
                self.injectButton.title = "Injecting..."
                return
            }
            
            if self.forceAllowPush {
                self.injectButton.isEnabled = true
                self.injectButton.title = "Force Inject Payload"
            } else {
                self.injectButton.isEnabled = self.canPush
                self.injectButton.title = "Inject Payload"
            }
        }
    }
    
    // MARK: - Key Events
    
    override func flagsChanged(with event: NSEvent) {
        forceAllowPush = event.modifierFlags.contains(.shift)
        updatePushState()
    }
    
    // MARK: - Payload Handling
    
    func didAcceptDroppedPayload(url: URL) {
        loadPayload(url: url)
    }
    
    func loadPayload(url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            addConsoleLine(line: "[error] Payload file not found: \(url.path)")
            return
        }
        
        guard url.pathExtension.lowercased() == "bin" else {
            addConsoleLine(line: "[error] File must have a .bin extension.")
            return
        }
        
        selectedPayloadURL = url
        addRecentPath(url.path)
        
        do {
            let data = try Data(contentsOf: url)
            let type = TegraDevice.inferPayloadType(payload: data)
            inferredPayloadType = type
            
            let sizeString = ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
            
            payloadNameLabel.stringValue = url.lastPathComponent
            payloadNameLabel.toolTip = url.path
            payloadDetailLabel.stringValue = sizeString
            
            payloadTypeBadge.isHidden = false
            payloadTypeBadge.stringValue = "•  \(type.title)"
            
            if type.isDangerous {
                payloadTypeBadge.textColor = NSColor.systemRed
                addConsoleLine(line: "[warning] \(type.title) selected. This modifies boot partitions so the console only boots to RCM.")
            } else {
                payloadTypeBadge.textColor = NSColor.controlAccentColor
            }
            
            addConsoleLine(line: "Payload selected: \(url.lastPathComponent) (\(type.title), \(sizeString))")
            
            // Check if RCM device is already connected
            let hasRCM = devices.contains(where: {
                $0.deviceInfo.vendorId == VID.RCM.rawValue &&
                $0.deviceInfo.productId == PID.RCM.rawValue
            })
            canPush = hasRCM
            updatePushState()
            
            if doAutopush && canPush {
                triggerAutoPushIfNeeded()
            }
        } catch {
            addConsoleLine(line: "[error] Could not read payload file: \(error.localizedDescription)")
        }
    }
    
    private func addRecentPath(_ path: String) {
        var paths = UserDefaults.standard.array(forKey: recentPathsKey) as? [String] ?? []
        paths.removeAll { $0 == path }
        paths.insert(path, at: 0)
        
        if paths.count > maxRecentPaths {
            paths = Array(paths.prefix(maxRecentPaths))
        }
        
        UserDefaults.standard.set(paths, forKey: recentPathsKey)
        UserDefaults.standard.synchronize()
        refreshRecentPopUp()
    }
    
    private func refreshRecentPopUp() {
        recentPopUp.removeAllItems()
        recentPopUp.addItem(withTitle: "Recent Payloads")
        
        let paths = UserDefaults.standard.array(forKey: recentPathsKey) as? [String] ?? []
        guard !paths.isEmpty else {
            let emptyItem = NSMenuItem(title: "No recent files", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            recentPopUp.menu?.addItem(emptyItem)
            return
        }
        
        recentPopUp.menu?.addItem(NSMenuItem.separator())
        
        for path in paths {
            let url = URL(fileURLWithPath: path)
            let item = NSMenuItem(title: url.lastPathComponent, action: #selector(onRecentItemClick(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = path
            item.toolTip = path
            recentPopUp.menu?.addItem(item)
        }
        
        recentPopUp.menu?.addItem(NSMenuItem.separator())
        let clearItem = NSMenuItem(title: "Clear Recent", action: #selector(clearRecentPaths), keyEquivalent: "")
        clearItem.target = self
        recentPopUp.menu?.addItem(clearItem)
    }
    
    @objc private func onRecentItemClick(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        loadPayload(url: URL(fileURLWithPath: path))
    }
    
    @objc private func clearRecentPaths() {
        UserDefaults.standard.removeObject(forKey: recentPathsKey)
        UserDefaults.standard.synchronize()
        refreshRecentPopUp()
    }
    
    @objc func onRecentPayloadSelected(_ sender: NSPopUpButton) {
        // Handled via menu items
    }
    
    // MARK: - Injection Flow
    
    private func triggerAutoPushIfNeeded() {
        if inferredPayloadType.isDangerous {
            addConsoleLine(line: "[safety] Auto-inject paused: \(inferredPayloadType.title) modifies boot partitions. Click Inject Payload to confirm.")
            return
        }
        go()
    }
    
    private func go() {
        guard let device = devices.first(where: {
            $0.deviceInfo.vendorId == VID.RCM.rawValue &&
            $0.deviceInfo.productId == PID.RCM.rawValue
        }) else {
            addConsoleLine(line: "[error] No RCM device connected.")
            return
        }
        
        guard let payloadURL = selectedPayloadURL else {
            addConsoleLine(line: "[error] No payload selected.")
            return
        }
        
        guard FileManager.default.fileExists(atPath: payloadURL.path) else {
            addConsoleLine(line: "[error] The payload file does not exist.")
            return
        }
        
        guard let intermezzoPath = Bundle.main.path(forResource: "intermezzo", ofType: "bin") else {
            addConsoleLine(line: "[error] intermezzo.bin is missing from the app bundle.")
            return
        }
        
        isInjecting = true
        updatePushState()
        
        customProgressBar.doubleValue = 10.0
        customProgressBar.isHidden = false
        addConsoleLine(line: "Injecting payload: \(payloadURL.lastPathComponent)")
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                let payloadData = try Data(contentsOf: payloadURL)
                try device.pushPayload(payloadData: payloadData, intermezzoPath: intermezzoPath)
                
                DispatchQueue.main.async {
                    self.isInjecting = false
                    self.customProgressBar.doubleValue = 100.0
                    self.addConsoleLine(line: "Payload injected successfully.")
                    self.updateConnectionStatus(.payloadLaunched(self.inferredPayloadType))
                    self.updatePushState()
                    
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        if !self.isInjecting {
                            self.customProgressBar.isHidden = true
                            self.customProgressBar.doubleValue = 0.0
                        }
                    }
                }
            } catch let error as TegraDeviceError {
                DispatchQueue.main.async {
                    self.isInjecting = false
                    self.customProgressBar.isHidden = true
                    self.customProgressBar.doubleValue = 0.0
                    self.updatePushState()
                    
                    switch error {
                    case .BadId:
                        self.addConsoleLine(line: "[error] Device ID returned all zeroes. Reboot the console into RCM.")
                    case .ProbablyAlreadyInRcm:
                        if self.doAutopush {
                            self.addConsoleLine(line: "[warning] Auto-inject skipped: console is already in an active or interrupted state.")
                        } else {
                            self.addConsoleLine(line: "[error] The console is in an invalid state. Reboot into RCM.")
                        }
                    case .IoReadPipeError(let desc):
                        self.addConsoleLine(line: "[error] Connection error during read: \(desc). Try a different USB cable or port.")
                    default:
                        self.addConsoleLine(line: "[error] Injection failed: \(error)")
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.isInjecting = false
                    self.customProgressBar.isHidden = true
                    self.customProgressBar.doubleValue = 0.0
                    self.updatePushState()
                    self.addConsoleLine(line: "[error] \(error.localizedDescription)")
                }
            }
        }
    }
    
    // MARK: - Actions
    
    @IBAction func onPushPress(_ sender: Any) {
        go()
    }
    
    @IBAction func onPayloadPress(_ sender: Any) {
        selectBlob()
    }
    
    @IBAction func onAutopushToggle(_ sender: NSButton) {
        let isEnabled = autopushToggle.state == .on
        doAutopush = isEnabled
        UserDefaults.standard.set(isEnabled ? 1 : 0, forKey: autopushKey)
        UserDefaults.standard.synchronize()
        
        if doAutopush && canPush {
            triggerAutoPushIfNeeded()
        }
    }
    
    func selectBlob() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        if #available(macOS 12.0, *) {
            panel.allowedContentTypes = [UTType(filenameExtension: "bin") ?? .data]
        } else {
            panel.allowedFileTypes = ["bin"]
        }
        
        if panel.runModal() == .OK, let url = panel.url {
            loadPayload(url: url)
        }
    }
    
    // MARK: - USB Observers
    
    @objc func usbConnected(notification: NSNotification) {
        guard let nobj = notification.object as? NSDictionary,
              let deviceInfo = nobj["device"] as? USBDevice else {
            return
        }
        
        let tegra = TegraDevice(deviceInfo)
        devices.append(tegra)
        
        if deviceInfo.vendorId == VID.RCM.rawValue && deviceInfo.productId == PID.RCM.rawValue {
            DispatchQueue.main.async {
                self.addConsoleLine(line: "Nintendo Switch (RCM) connected.")
                self.updateConnectionStatus(.rcmConnected)
                self.canPush = self.selectedPayloadURL != nil
                self.updatePushState()
                
                if self.doAutopush && self.canPush {
                    self.triggerAutoPushIfNeeded()
                }
            }
        } else if deviceInfo.vendorId == VID.NX.rawValue && deviceInfo.productId == PID.NX.rawValue {
            DispatchQueue.main.async {
                self.addConsoleLine(line: "Nintendo Switch (Standard mode) connected.")
                self.updateConnectionStatus(.standardConnected)
            }
        }
    }
    
    @objc func usbDisconnected(notification: NSNotification) {
        guard let nobj = notification.object as? NSDictionary,
              let id = nobj["id"] as? UInt64 else {
            return
        }
        
        DispatchQueue.main.async {
            if let index = self.devices.firstIndex(where: { $0.deviceInfo.id == id }) {
                self.devices.remove(at: index)
                self.addConsoleLine(line: "Device disconnected.")
                self.connectedDevice = nil
                self.canPush = false
                self.updateConnectionStatus(.disconnected)
                self.updatePushState()
            }
        }
    }
    
    @objc func onProgressUpdate(notification: NSNotification) {
        guard let p = notification.userInfo?["by"] as? Double else { return }
        DispatchQueue.main.async {
            self.customProgressBar.isHidden = false
            self.customProgressBar.doubleValue = p
        }
    }
    
    @objc func onPayloadTypeInferred(notification: NSNotification) {
        if let typeRawValue = notification.object as? Int,
           let type = NXPayload(rawValue: typeRawValue) {
            inferredPayloadType = type
        }
    }
    
    @objc func onMenubarOpen(notification: NSNotification) {
        selectBlob()
    }
    
    @IBAction func onMenubarPayloadPress(_ sender: Any) {
        go()
    }
    
    // MARK: - Activity Log
    
    func addConsoleLine(line: String) {
        let msg = NSAttributedString(string: line + "\n")
        DispatchQueue.main.async {
            self.consoleOutputBox.textStorage?.append(msg)
            self.consoleOutputBox.scrollToEndOfDocument(nil)
        }
    }
    
    @objc private func toggleLogExpansion() {
        isLogExpanded.toggle()
        logDisclosureButton.title = isLogExpanded ? "▾ Hide Activity Log" : "▸ Show Activity Log"
        clearLogButton.isHidden = !isLogExpanded
        logScrollView.isHidden = !isLogExpanded
        logHeightConstraint?.constant = isLogExpanded ? 120 : 0
        
        if let window = view.window {
            var frame = window.frame
            let delta: CGFloat = isLogExpanded ? 130 : -130
            frame.origin.y -= delta
            frame.size.height += delta
            window.setFrame(frame, display: true, animate: true)
        }
        
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.allowsImplicitAnimation = true
            self.view.layoutSubtreeIfNeeded()
        }
    }
    @objc private func clearLog() {
        consoleOutputBox.string = ""
    }
    
    // MARK: - Updates
    
    private func checkForUpdates() {
        guard let url = URL(string: crystalrcmGh) else { return }
        
        let task = URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            guard let self = self,
                  error == nil,
                  let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tagName = json["tag_name"] as? String,
                  let htmlURL = json["html_url"] as? String else {
                return
            }
            
            let latestVersion = tagName.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
            if self.isNewerVersion(latestVersion, than: self.ver) {
                DispatchQueue.main.async {
                    self.showUpdateBanner(version: latestVersion, url: htmlURL)
                }
            }
        }
        task.resume()
    }
    
    private func isNewerVersion(_ latest: String, than current: String) -> Bool {
        let latestComponents = latest.split(separator: ".").compactMap { Int($0) }
        let currentComponents = current.split(separator: ".").compactMap { Int($0) }
        
        for i in 0..<max(latestComponents.count, currentComponents.count) {
            let latestPart = i < latestComponents.count ? latestComponents[i] : 0
            let currentPart = i < currentComponents.count ? currentComponents[i] : 0
            if latestPart > currentPart { return true }
            if latestPart < currentPart { return false }
        }
        return false
    }
    
    private func showUpdateBanner(version: String, url: String) {
        updateURL = url
        updateBannerBox.isHidden = false
        
        let attr = NSMutableAttributedString(string: "CrystalRCM v\(version) is available. Click here to open release page.")
        let range = NSRange(location: 0, length: attr.length)
        attr.addAttribute(.link, value: url, range: range)
        attr.addAttribute(.foregroundColor, value: NSColor.systemBlue, range: range)
        attr.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        
        updateBannerLabel.attributedStringValue = attr
    }
}
