#!/usr/bin/env python3
"""Exercise the real screen cache's privacy state transitions without host TCC.

Appends same-file test code to an unchanged copy of ScreenCaptureSource.swift so
Swift's private members remain private in the shipping module. This does not
claim successful ScreenCaptureKit capture, authorization, or display movement.
"""
import argparse
from pathlib import Path
import subprocess

repo = Path(__file__).resolve().parents[3]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--image', required=True, type=Path)
parser.add_argument('--output', type=Path, default=repo / 'build/devices/acceptance/screen-frame-state')
args = parser.parse_args()
assert args.image.is_absolute() and args.image.is_file()
out = args.output.resolve(); out.mkdir(parents=True, exist_ok=True)
source = (repo / 'extras/devices/host/ScreenCaptureSource.swift').read_text()
source += r'''
extension ScreenCaptureSource {
    static func verifyPrivacyState(imagePath: String) throws {
        let source = ScreenCaptureSource()
        let owner = NSObject(), oldOwner = NSObject()
        let currentID = ObjectIdentifier(owner), oldID = ObjectIdentifier(oldOwner)
        guard let image = CIImage(contentsOf: URL(fileURLWithPath: imagePath)) else { fatalError("real screenshot cannot be read") }
        var results: [[String: Any]] = []
        func check(_ name: String, _ condition: Bool) {
            results.append(["name": name, "passed": condition])
            precondition(condition, name)
        }
        func install() {
            source.acceptedStream = currentID
            source.latest = image
            source.encoded = nil
            source.outputSize = image.extent.size
            source.pixelOffset = .zero
        }
        install()
        let before = source.latestFrame()!
        check("real image is encoded", !before.jpeg.isEmpty)
        _ = source.handleFrameStatus(.idle, from: currentID)
        check("idle keeps unchanged desktop frame", source.latestFrame()?.jpeg == before.jpeg)
        for (name, status) in [("blank", SCFrameStatus.blank), ("suspended", .suspended), ("stopped", .stopped)] {
            install()
            _ = source.latestFrame()
            let decision = source.handleFrameStatus(status, from: currentID)
            switch decision { case .interrupt: check(name + " interrupts", true); default: check(name + " interrupts", false) }
            check(name + " cannot return an old photo", source.latestFrame() == nil && source.latest == nil && source.encoded == nil)
            check(name + " invalidates old stream", source.acceptedStream == nil)
        }
        install()
        _ = source.handleFrameStatus(.blank, from: oldID)
        check("stale stream status cannot revoke current frame", source.latestFrame() != nil && source.acceptedStream == currentID)
        for status in [SCFrameStatus.started, .complete] {
            let decision = source.handleFrameStatus(status, from: currentID)
            switch decision { case .accept: check("valid first/complete frame accepted", true); default: check("valid first/complete frame accepted", false) }
        }
        let report: [String: Any] = ["passed": true, "scope": "screen frame cache state only; no host permission or real SCStream exercised", "checks": results]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        FileHandle.standardOutput.write(data)
    }
}
@main struct TestRunner {
    static func main() throws { try ScreenCaptureSource.verifyPrivacyState(imagePath: CommandLine.arguments[1]) }
}
'''
(out / 'ScreenCaptureSource+Tests.swift').write_text(source)
command = ['xcrun', '--sdk', 'macosx', 'swiftc', '-swift-version', '5', '-parse-as-library',
           '-target', 'arm64-apple-macos15.0', str(out / 'ScreenCaptureSource+Tests.swift'),
           str(repo / 'extras/devices/host/FrameProducer.swift'), '-framework', 'AppKit',
           '-framework', 'ScreenCaptureKit', '-framework', 'CoreImage', '-framework', 'ImageIO',
           '-o', str(out / 'ScreenFrameStateProbe')]
built = subprocess.run(command, capture_output=True, text=True)
(out / 'compile.log').write_text(built.stdout + built.stderr); built.check_returncode()
result = subprocess.run([str(out / 'ScreenFrameStateProbe'), str(args.image)], capture_output=True, text=True)
(out / 'acceptance.json').write_text(result.stdout)
(out / 'probe.log').write_text(result.stderr)
result.check_returncode()
print(out / 'acceptance.json')
