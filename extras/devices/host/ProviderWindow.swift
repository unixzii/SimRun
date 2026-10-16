// In-process optional device service and settings window for the SimRun host.
import AppKit

private final class ProviderDocumentView: NSView {
    override var isFlipped: Bool { true }
}

final class ProviderWindow: NSObject {
    private let server = CameraSocketServer()
    private var window: NSWindow?
    private var started = false
    private var location: LocationSettingsView?
    private let connection = NSTextField(wrappingLabelWithString:"Starting camera provider")
    private let capture = NSTextField(wrappingLabelWithString:"Image sources only; screen capture is unsupported in this build")

    override init() {
        super.init()
        server.onStatus = { [weak self] status in
            guard let self, self.started else { return }
            self.connection.stringValue = status
        }
    }

    /// No window, prompt or menu is created by starting the optional service.
    func start() {
        dispatchPrecondition(condition:.onQueue(.main))
        guard !started else { return }
        // The existing view owns the file-private settings store. Constructing
        // its controls initializes location.json without presenting any UI.
        if location == nil { location = LocationSettingsView() }
        do {
            try server.start()
            started = true
        } catch {
            connection.stringValue = "Device service unavailable: \(error.localizedDescription)"
        }
    }

    func show() {
        dispatchPrecondition(condition:.onQueue(.main))
        start()
        if window == nil { buildWindow() }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps:true)
    }

    func stop() {
        dispatchPrecondition(condition:.onQueue(.main))
        started = false
        server.stop()
        // Session producers schedule their consumer releases on main. Keep the
        // controller/module alive while those already-enqueued releases finish.
        window?.close()
        connection.stringValue = "Device service stopped"
    }

    private func buildWindow() {
        let height = min(820, max(500, (NSScreen.main?.visibleFrame.height ?? 900) - 60))
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:620,height:height),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        window.contentMinSize = NSSize(width:540,height:440)
        window.title = "SimRun Device Settings"; window.isReleasedWhenClosed = false
        self.window = window
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        let title = NSTextField(labelWithString:"Simulated camera")
        title.font = NSFont.boldSystemFont(ofSize:18)
        stack.addArrangedSubview(title); stack.addArrangedSubview(connection); stack.addArrangedSubview(capture)
        let explanation = NSTextField(wrappingLabelWithString:"Virtual camera authorization belongs to the test App. Configure an explicit image source. Screen capture is unsupported in this build; no host Screen Recording permission is requested. Reopen the camera after changing an interrupted session.")
        explanation.font = NSFont.systemFont(ofSize:11); explanation.textColor = .secondaryLabelColor
        stack.addArrangedSubview(explanation)
        for label in [connection, capture, explanation] {
            label.widthAnchor.constraint(equalTo:stack.widthAnchor).isActive = true
        }
        let separator = NSBox(); separator.boxType = .separator
        stack.addArrangedSubview(separator)
        separator.widthAnchor.constraint(equalTo:stack.widthAnchor).isActive = true
        if let location {
            stack.addArrangedSubview(location)
            location.widthAnchor.constraint(equalTo:stack.widthAnchor).isActive = true
        }
        let content = window.contentView!
        let scroll = NSScrollView(frame:content.bounds)
        scroll.autoresizingMask = [.width,.height]; scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let document = ProviderDocumentView(frame:content.bounds)
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        content.addSubview(scroll)
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo:scroll.contentView.widthAnchor),
            document.heightAnchor.constraint(greaterThanOrEqualTo:scroll.contentView.heightAnchor),
            stack.leadingAnchor.constraint(equalTo:document.leadingAnchor,constant:18),
            stack.trailingAnchor.constraint(equalTo:document.trailingAnchor,constant:-18),
            stack.topAnchor.constraint(equalTo:document.topAnchor,constant:18),
            stack.bottomAnchor.constraint(equalTo:document.bottomAnchor,constant:-18)
        ])
        window.center()
    }

}

// Accessed exclusively on main. The host retains this dylib until process exit;
// it owns no NSApplication lifecycle, delegate, main menu or activation policy.
private var deviceController: ProviderWindow?
private func controller() -> ProviderWindow {
    dispatchPrecondition(condition:.onQueue(.main))
    if let deviceController { return deviceController }
    let created = ProviderWindow()
    deviceController = created
    return created
}
private func performOnMain(_ operation: @escaping () -> Void) {
    if Thread.isMainThread { operation() }
    else { DispatchQueue.main.async(execute:operation) }
}

@_cdecl("SimRunDevicesHostStart")
public func SimRunDevicesHostStart() {
    performOnMain { controller().start() }
}

@_cdecl("SimRunDevicesHostShowSettings")
public func SimRunDevicesHostShowSettings() {
    performOnMain { controller().show() }
}

@_cdecl("SimRunDevicesHostStop")
public func SimRunDevicesHostStop() {
    performOnMain { deviceController?.stop() }
}
