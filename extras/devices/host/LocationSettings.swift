import AppKit
import Foundation
import Darwin

private struct LocationSettingsError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

/// Shared only by apps explicitly configured to use this file. No host GPS/TCC.
private final class LocationSettingsStore {
    let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/SimRun/Devices/location.json")
    static let authorizationNames = ["notDetermined", "authorizedWhenInUse", "authorizedAlways", "denied", "restricted"]
    static let requestNames = ["authorizedWhenInUse", "authorizedAlways", "denied"]
    static let shanghai: [String: Any] = [
        "name": "Shanghai (simulated)", "latitude": 31.2304, "longitude": 121.4737,
        "horizontalAccuracy": 5, "authorization": "notDetermined",
        "requestAuthorization": "authorizedWhenInUse", "enabled": true
    ]

    func loadOrCreate() throws -> (value: [String: Any], created: Bool) {
        try prepareDirectory()
        var info = stat()
        if lstat(url.path, &info) != 0 {
            guard errno == ENOENT else { throw LocationSettingsError("Cannot inspect location.json") }
            let created = try write(Self.shanghai, onlyIfAbsent: true)
            return (try read(), created)
        }
        return (try read(), false)
    }

    func read() throws -> [String: Any] {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid() else {
            throw LocationSettingsError("location.json must be a regular file owned by this user")
        }
        guard chmod(url.path, 0o600) == 0 else { throw LocationSettingsError("Cannot secure location.json permissions") }
        let data = try Data(contentsOf: url)
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LocationSettingsError("location.json must contain a JSON object")
        }
        try validate(value)
        return value
    }

    func validate(_ value: [String: Any]) throws {
        func number(_ key: String) -> Double? {
            guard let raw = value[key] as? NSNumber, CFGetTypeID(raw) != CFBooleanGetTypeID(), raw.doubleValue.isFinite else { return nil }
            return raw.doubleValue
        }
        guard let latitude = number("latitude"), (-90...90).contains(latitude) else {
            throw LocationSettingsError("Latitude must be a finite number between -90 and 90")
        }
        guard let longitude = number("longitude"), (-180...180).contains(longitude) else {
            throw LocationSettingsError("Longitude must be a finite number between -180 and 180")
        }
        guard let accuracy = number("horizontalAccuracy"), accuracy >= 0 else {
            throw LocationSettingsError("Horizontal accuracy must be finite and nonnegative")
        }
        guard let authorization = value["authorization"] as? String, Self.authorizationNames.contains(authorization),
              let request = value["requestAuthorization"] as? String, Self.requestNames.contains(request),
              let enabled = value["enabled"] as? NSNumber, CFGetTypeID(enabled) == CFBooleanGetTypeID() else {
            throw LocationSettingsError("Location service switch or authorization policy is invalid")
        }
    }

    @discardableResult
    func write(_ value: [String: Any], onlyIfAbsent: Bool = false) throws -> Bool {
        try validate(value)
        try prepareDirectory()
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".location-\(UUID().uuidString).tmp")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw LocationSettingsError("Cannot create a private temporary location file") }
        defer { unlink(temporary.path) }
        var good = fchmod(fd, 0o600) == 0
        data.withUnsafeBytes { buffer in
            var offset = 0
            while good && offset < buffer.count {
                let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                if count <= 0 { good = false; break }
                offset += count
            }
        }
        if close(fd) != 0 { good = false }
        guard good else { throw LocationSettingsError("Failed to write location settings; previous file is unchanged") }
        if onlyIfAbsent {
            // Atomic first creation without overwriting another process's file.
            if link(temporary.path, url.path) == 0 { return true }
            if errno == EEXIST { return false }
        } else if rename(temporary.path, url.path) == 0 { return true }
        throw LocationSettingsError("Cannot publish location settings; previous file is unchanged")
    }

    private func prepareDirectory() throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(directory.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid(),
              chmod(directory.path, 0o700) == 0 else { throw LocationSettingsError("Cannot secure the location settings directory") }
    }
}

final class LocationSettingsView: NSStackView {
    private let store = LocationSettingsStore()
    private let enabled = NSButton(checkboxWithTitle: "Enable simulated location services", target: nil, action: nil)
    private let latitude = NSTextField(string: "31.2304")
    private let longitude = NSTextField(string: "121.4737")
    private let authorization = NSPopUpButton(frame: .zero, pullsDown: false)
    private let request = NSPopUpButton(frame: .zero, pullsDown: false)
    private let current = NSTextField(wrappingLabelWithString: "No valid saved location settings")
    private let result = NSTextField(wrappingLabelWithString: "")
    private var saved = LocationSettingsStore.shanghai

    init() {
        super.init(frame: .zero)
        orientation = .vertical; alignment = .leading; spacing = 9
        let title = NSTextField(labelWithString: "Simulated location")
        title.font = NSFont.boldSystemFont(ofSize: 15)
        addArrangedSubview(title)
        enabled.state = .on
        enabled.setAccessibilityIdentifier("location.enabled")
        addArrangedSubview(enabled)
        latitude.setAccessibilityLabel("Latitude"); latitude.setAccessibilityIdentifier("location.latitude")
        longitude.setAccessibilityLabel("Longitude"); longitude.setAccessibilityIdentifier("location.longitude")
        latitude.widthAnchor.constraint(equalToConstant: 140).isActive = true
        longitude.widthAnchor.constraint(equalToConstant: 140).isActive = true
        let coordinates = NSStackView(views: [NSTextField(labelWithString: "Latitude"), latitude,
                                             NSTextField(labelWithString: "Longitude"), longitude])
        coordinates.orientation = .horizontal; coordinates.spacing = 8
        addArrangedSubview(coordinates)
        authorization.addItems(withTitles: LocationSettingsStore.authorizationNames)
        authorization.setAccessibilityLabel("Location authorization"); authorization.setAccessibilityIdentifier("location.authorization")
        request.addItems(withTitles: LocationSettingsStore.requestNames)
        request.setAccessibilityLabel("Authorization request result"); request.setAccessibilityIdentifier("location.requestAuthorization")
        addArrangedSubview(row("Location authorization", authorization))
        addArrangedSubview(row("Authorization request result", request))
        let apply = NSButton(title: "Apply location settings", target: self, action: #selector(applySettings))
        apply.setAccessibilityIdentifier("location.apply")
        let shanghai = NSButton(title: "Use Shanghai", target: self, action: #selector(useShanghai))
        shanghai.setAccessibilityIdentifier("location.shanghai")
        let buttons = NSStackView(views: [apply, shanghai]); buttons.orientation = .horizontal; buttons.spacing = 10
        addArrangedSubview(buttons)
        current.setAccessibilityIdentifier("location.current")
        result.setAccessibilityIdentifier("location.result")
        addArrangedSubview(current)
        let scope = NSTextField(wrappingLabelWithString: "Only apps configured to use this location.json receive these simulated settings. This does not request the Mac's location permission.")
        scope.font = NSFont.systemFont(ofSize: 11); scope.textColor = .secondaryLabelColor
        addArrangedSubview(scope)
        let path = NSTextField(wrappingLabelWithString: "Configuration: ~/Library/Application Support/SimRun/Devices/location.json")
        path.font = NSFont.systemFont(ofSize: 10); path.textColor = .secondaryLabelColor
        path.isSelectable = true
        addArrangedSubview(path); addArrangedSubview(result)
        for label in [current, scope, path, result] { label.widthAnchor.constraint(equalTo: widthAnchor).isActive = true }
        do {
            let loaded = try store.loadOrCreate()
            saved = loaded.value; populate(saved); showCurrent(saved)
            showResult(loaded.created ? "Created Shanghai default simulation." : "Loaded saved location settings.", error: false)
        } catch { showResult(error.localizedDescription, error: true) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func row(_ label: String, _ control: NSView) -> NSStackView {
        let view = NSStackView(views: [NSTextField(labelWithString: label), control])
        view.orientation = .horizontal; view.spacing = 10
        return view
    }
    private func populate(_ value: [String: Any]) {
        latitude.stringValue = String((value["latitude"] as! NSNumber).doubleValue)
        longitude.stringValue = String((value["longitude"] as! NSNumber).doubleValue)
        enabled.state = (value["enabled"] as! NSNumber).boolValue ? .on : .off
        authorization.selectItem(withTitle: value["authorization"] as! String)
        request.selectItem(withTitle: value["requestAuthorization"] as! String)
    }
    private func showCurrent(_ value: [String: Any]) {
        let services = (value["enabled"] as? NSNumber)?.boolValue == true ? "on" : "off"
        current.stringValue = "Saved simulation: \(value["latitude"]!) , \(value["longitude"]!) · services \(services) · authorization \(value["authorization"]!) · request → \(value["requestAuthorization"]!)"
    }
    private func showResult(_ message: String, error: Bool) {
        result.stringValue = (error ? "Error: " : "Success: ") + message
        result.textColor = error ? .systemRed : .secondaryLabelColor
    }
    @objc private func applySettings() {
        guard let lat = Double(latitude.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)), lat.isFinite, (-90...90).contains(lat) else {
            showResult("Latitude must be a finite number between -90 and 90", error: true); return
        }
        guard let lon = Double(longitude.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)), lon.isFinite, (-180...180).contains(lon) else {
            showResult("Longitude must be a finite number between -180 and 180", error: true); return
        }
        var next = (try? store.read()) ?? saved
        next["latitude"] = lat; next["longitude"] = lon
        next["horizontalAccuracy"] = next["horizontalAccuracy"] ?? 5
        next["enabled"] = enabled.state == .on
        next["authorization"] = authorization.titleOfSelectedItem ?? "notDetermined"
        next["requestAuthorization"] = request.titleOfSelectedItem ?? "authorizedWhenInUse"
        next["name"] = lat == 31.2304 && lon == 121.4737 ? "Shanghai (simulated)" : "Custom (simulated)"
        do {
            try store.write(next)
            saved = next; showCurrent(next)
            showResult("Applied. Apps using this file can read the new settings.", error: false)
        } catch { showResult(error.localizedDescription, error: true) }
    }
    @objc private func useShanghai() {
        // Preserve the selected service switch and both authorization policies.
        latitude.stringValue = "31.2304"; longitude.stringValue = "121.4737"
        applySettings()
    }
}
