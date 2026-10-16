"""Real runtime acceptance through SimRun, not mocks of the injected APIs.

Synthetic image-only protocol control; not live-screen acceptance.
Run after make core SIMRUN_DEVICES=1.
The only deliberate sleeps measure absence of callbacks after stop/denial.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import time
import uuid

from PIL import Image, ImageDraw

REPO = Path(__file__).resolve().parents[3]
OUT = REPO / "build/devices/acceptance/synthetic-image-control"
OUT.mkdir(parents=True, exist_ok=True)
CLI = str(REPO / "build/bin/simrun")
PROFILE = "synthetic-image-" + uuid.uuid4().hex[:12]
APP = "dev.simrun.DeviceProbe"
checks = []


def save(name, data):
    (OUT / name).write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")


def evaluate(script):
    result = subprocess.run([CLI, "eval", APP, "-p", PROFILE, script], capture_output=True, text=True, timeout=25)
    if result.returncode:
        raise RuntimeError(result.stderr)
    return result.stdout


def probe(name):
    value = json.loads(evaluate('const w=objc.send(objc.send("UIApplication","sharedApplication"),"windows")[0]; return objc.send(objc.send(w,"rootViewController"),"probeState");'))
    save(name + ".json", value)
    return value


def tap(name):
    evaluate(f'await app.getByRole("button",{{name:{json.dumps(name)},exact:true}}).tap();')


def screenshot(name):
    subprocess.run([CLI, "screenshot", APP, "-p", PROFILE, "-o", str(OUT / name)], check=True, capture_output=True)


def check(name, condition, evidence):
    checks.append(dict(name=name, passed=bool(condition), evidence=evidence))
    save("acceptance.json", dict(profile=PROFILE, checks=checks))
    if not condition:
        raise AssertionError(name)
    print("PASS", name, flush=True)


def location(**changes):
    value = dict(latitude=31.22046, longitude=121.45801, horizontalAccuracy=5,
                 authorization="notDetermined", requestAuthorization="authorizedWhenInUse")
    value.update(changes)
    if value.get("authorization") is None:
        value.pop("authorization", None)
    temporary = OUT / "location-acceptance.tmp"
    temporary.write_text(json.dumps(value), encoding="utf-8")
    temporary.replace(OUT / "location-acceptance.json")


location(authorization=None)  # Default must survive the status check before the first fix.
fixture = Image.new("RGB", (640, 480), (20, 80, 180))
draw = ImageDraw.Draw(fixture)
draw.rectangle((320, 0, 639, 479), fill=(230, 160, 40))
draw.text((50, 220), "SIMRUN CAMERA FIXTURE 640x480", fill="white")
fixture.save(OUT / "fixture.png")
save("camera.json", dict(name="SimRun static photo", devices=[
    dict(id="cmf-" + position, name="SimRun " + position, position=position,
         source=dict(kind="image", path=str(OUT / "fixture.png")))
    for position in ("back", "front")
]))
env = dict(os.environ, SIMRUN_LOCATION_FILE=str(OUT / "location-acceptance.json"),
           SIMRUN_CAMERA_FILE=str(OUT / "camera.json"))
log = (OUT / "acceptance-probe.log").open("w")
process = subprocess.Popen([CLI, "run", "--headless", "--mute", "-p", PROFILE,
                            "--insert", str(REPO / "build/devices/SimRunDevices.dylib"),
                            str(REPO / "build/devices/DeviceProbe.app")], env=env,
                           stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
for _ in range(80):
    ready = subprocess.run([CLI, "eval", APP, "-p", PROFILE, "true"], capture_output=True)
    if ready.returncode == 0:
        break
    if process.poll() is not None:
        raise RuntimeError("Probe exited: " + str(process.returncode))
    time.sleep(.25)
else:
    raise RuntimeError("Probe did not become ready")

initial = probe("01-initial")
check("authorization begins undetermined", initial["authorization"] == 0, "01-initial.json")
tap("Request location")
evaluate('await expect(app.getByText(/Updates=1 /)).toBeVisible();')
single = probe("02-single-location")
check("single fix coordinate and authorization", single["authorization"] == 4 and single["latitude"] == 31.22046 and single["longitude"] == 121.45801 and single["accuracy"] == 5, "02-single-location.json")
time.sleep(1.5)
check("requestLocation emits once", probe("03-single-stable")["updates"] == single["updates"], "03-single-stable.json")
tap("Start location")
evaluate('await expect(app.getByText(/Updates=[3-9] /)).toBeVisible();')
location(latitude=31.2304, longitude=121.4737, authorization=None)
evaluate('await expect(app.getByText(/31.2304,121.4737/)).toBeVisible();')
changed = probe("04-live-coordinate")
check("continuous updates read changed fixture and fresh timestamp", changed["latitude"] == 31.2304 and changed["longitude"] == 121.4737 and changed["timestamp"] > single["timestamp"], "04-live-coordinate.json")
tap("Stop location")
stopped = probe("05-location-stopped")
time.sleep(2.2)
check("stopUpdatingLocation cancels callbacks", probe("06-location-stable")["updates"] == stopped["updates"], "05-location-stopped.json + 06-location-stable.json")
location(authorization="denied")
tap("Request location")
denied = probe("07-denied")
check("denied returns error without coordinate callback or cached location", denied["authorization"] == 2 and denied["error"] == "kCLErrorDomain:1" and denied["updates"] == stopped["updates"] and not denied["cachedLocationAvailable"], "07-denied.json")
location(authorization="authorizedWhenInUse", enabled=False)
tap("Request location")
disabled = probe("08-disabled")
check("disabled location returns denied without updates", disabled["authorization"] == 2 and disabled["updates"] == stopped["updates"], "08-disabled.json")
location(authorization="authorizedWhenInUse")
tap("Request location")
restored = probe("09-location-restored")
check("location recovers after permission restore", restored["authorization"] == 4 and restored["updates"] == stopped["updates"] + 1, "09-location-restored.json")
tap("Start camera")
evaluate('await expect(app.getByText(/frames=[1-9]/)).toBeVisible({timeout:10000});')
frames = probe("10-camera-frames")
check("camera discovers devices and receives fixture frames", frames["videoDevices"] == 2 and frames["cameraAllowed"] and frames["frameWidth"] == 640 and frames["frameHeight"] == 480 and all(abs(a-b) <= 5 for a,b in zip(frames["frameFirstRGB"], (20,80,180))), "10-camera-frames.json")
check("exposure reset completes on virtual device", frames.get("exposureResetCompleted") is True, "10-camera-frames.json")
check("camera buffers carry propagated EXIF brightness attachment", frames.get("frameExifPresent") is True, "10-camera-frames.json")
check("video output honors NV12 video-range request", frames.get("framePixelFormat") == int.from_bytes(b"420v", "big"), "10-camera-frames.json")
screenshot("10-preview.png")
tap("Take photo")
evaluate('await expect(app.getByText(/Photos=1 completed=1/)).toBeVisible({timeout:10000});')
photo = probe("11-photo")
shutil.copy2(photo["photoPath"], OUT / "captured.jpg")
with Image.open(OUT / "captured.jpg") as capture:
    pixel = capture.convert("RGB").getpixel((10, 10))
    check("photo dimensions and RGB match fixture", capture.size == (640,480) and all(abs(a-b) <= 5 for a,b in zip(pixel,(20,80,180))), "fixture.png + captured.jpg")
tap("Take photo")
evaluate('await expect(app.getByText(/Photos=2 completed=2/)).toBeVisible({timeout:10000});')
time.sleep(.8)
second = probe("12-second-photo")
check("one processing and completion callback per shutter; monotonic frames", second["photos"] == 2 and second["completions"] == 2 and second["ptsMonotonic"] and second["frames"] > frames["frames"], "12-second-photo.json")
screenshot("12-photo.png")
tap("Stop camera")
time.sleep(.3)  # drain any already-delivered delegate callback
camera_stopped = probe("13-camera-stopped")
time.sleep(1.5)
check("stop camera stops frame callbacks", probe("14-camera-stable")["frames"] == camera_stopped["frames"], "13-camera-stopped.json + 14-camera-stable.json")
for button, fourcc, name in [("Use NV12 full range", b"420f", "15-full-range"), ("Use BGRA", b"BGRA", "16-bgra")]:
    tap(button)
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline:
        value = probe(name)
        if value.get("framePixelFormat") == int.from_bytes(fourcc,"big"):
            break
        time.sleep(.1)
    check(button + " delivers correct format and fixture colors", value.get("framePixelFormat") == int.from_bytes(fourcc,"big") and all(abs(a-b) <= 5 for a,b in zip(value["frameFirstRGB"], (20,80,180))), name + ".json")
    tap("Stop camera")
print("All checks passed. Probe left running for inspection:", PROFILE, flush=True)
