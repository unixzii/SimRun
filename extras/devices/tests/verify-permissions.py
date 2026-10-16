#!/usr/bin/env python3
"""Compile/run the 19-check negative-path permission probe without a provider.

The owned headless probe never discovers devices or starts an authorized camera.
Only its own bundle/profile is quit. It does not request macOS privacy access.
"""
import argparse
from datetime import datetime
import json
from pathlib import Path
import plistlib
import re
import subprocess
import time
import uuid

from acceptance_support import REPO, ProbeRun, save_json


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--profile")
    parser.add_argument("--dylib", type=Path, default=REPO / "build/devices/SimRunDevices.dylib")
    args = parser.parse_args()
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    out = (args.output or REPO / ("build/devices/acceptance/permission-acceptance-" + stamp)).resolve()
    profile = args.profile or "permissions-" + stamp + "-" + uuid.uuid4().hex[:6]
    out.mkdir(parents=True, exist_ok=True)
    app = out / "PermissionProbe.app"
    app.mkdir(exist_ok=True)
    bundle = "dev.simrun.CameraPermissionsProbe"
    info = plistlib.loads((REPO / "extras/devices/tests/Info.plist").read_bytes())
    info.update(CFBundleIdentifier=bundle, CFBundleName="PermissionProbe", CFBundleExecutable="PermissionProbe")
    (app / "Info.plist").write_bytes(plistlib.dumps(info))
    command = ["xcrun", "--sdk", "iphonesimulator", "clang", "-arch", "arm64",
               "-mios-simulator-version-min=17.0", "-fobjc-arc", "-Wno-deprecated-declarations",
               str(REPO / "extras/devices/tests/camera-permissions.m"),
               "-framework", "UIKit", "-framework", "AVFoundation", "-o", str(app / "PermissionProbe")]
    run = ProbeRun(app, bundle, profile, out, args.dylib)
    try:
        build = subprocess.run(command, capture_output=True, text=True)
        (out / "compile.log").write_text(build.stdout + build.stderr, encoding="utf-8")
        build.check_returncode()
        subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True, capture_output=True)
        run.start()
        deadline = time.monotonic() + 45
        report_path = None
        while time.monotonic() < deadline:
            log = (out / "probe.log").read_text(encoding="utf-8", errors="replace")
            match = re.search(r"CAMERA_PERMISSION_REPORT (.+)", log)
            if match and Path(match.group(1).strip()).is_file():
                report_path = Path(match.group(1).strip())
                break
            if run.process.poll() is not None:
                raise RuntimeError("Permission probe exited before producing results; see probe.log")
            time.sleep(.2)
        if report_path is None:
            raise TimeoutError("Permission probe did not finish; see probe.log")
        report = json.loads(report_path.read_text(encoding="utf-8"))
        # Inspect the actual transport log as well as its final connected flag:
        # a connect followed by busy-rejection is not an isolated negative test.
        observed_connection = "socket connected" in log or "connectionRejected" in log
        report.update(profile=profile, dylib=str(args.dylib.resolve()), providerConnectionObserved=observed_connection)
        save_json(out / "acceptance.json", report)
        if observed_connection or not report.get("passed") or len(report.get("checks", [])) != 19 or not all(c.get("passed") for c in report["checks"]):
            raise AssertionError("Expected 19 passing permission checks and no provider connection")
        print("19 permission checks passed; no provider connection:", out / "acceptance.json", flush=True)
    except BaseException as error:
        save_json(out / "runner-failure.json", dict(profile=profile, failure=str(error)))
        raise
    finally:
        run.close()


if __name__ == "__main__":
    main()
