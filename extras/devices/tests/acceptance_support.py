"""Small runtime harness shared by the opt-in acceptance scripts."""
import json
import os
from pathlib import Path
import signal
import subprocess
import time

REPO = Path(__file__).resolve().parents[3]
CLI = REPO / "build/bin/simrun"


def save_json(path, value):
    path = Path(path)
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    temporary.replace(path)


class ProbeRun:
    def __init__(self, app, bundle, profile, output, dylib):
        self.app, self.bundle, self.profile = Path(app), bundle, profile
        self.output, self.dylib = Path(output).resolve(), Path(dylib).resolve()
        self.process = self.log = None
        self.started = False
        self.output.mkdir(parents=True, exist_ok=True)

    def start(self, extra_env=None, *, headless=True):
        if not self.app.is_dir() or not self.dylib.is_file():
            raise RuntimeError("Build the probe and device dylib before acceptance")
        listed = subprocess.run([str(CLI), "list"], capture_output=True, text=True, timeout=10)
        if listed.returncode:
            raise RuntimeError(listed.stderr or "Cannot list SimRun instances")
        if any(self.profile in row.split() for row in listed.stdout.splitlines()):
            raise RuntimeError("Profile is already in use; choose a fresh --profile")
        env = dict(os.environ)
        for key in ("SIMRUN_CAMERA_FILE", "SIMRUN_LOCATION_FILE", "SIMRUN_ROLE"):
            env.pop(key, None)
        env.update(extra_env or {})
        self.log = (self.output / "probe.log").open("w", encoding="utf-8")
        command = [str(CLI), "run", "--mute", "-p", self.profile,
                   "--insert", str(self.dylib)]
        if headless:
            command.append("--headless")
        self.process = subprocess.Popen(command + [str(self.app.resolve())],
                                        stdout=self.log, stderr=subprocess.STDOUT, env=env)
        self.started = True

    def evaluate(self, script, timeout=20):
        value = subprocess.run([str(CLI), "eval", self.bundle, "-p", self.profile, script],
                               capture_output=True, text=True, timeout=timeout)
        if value.returncode:
            raise RuntimeError(value.stderr.strip() or value.stdout.strip())
        return value.stdout.strip()

    def wait_ready(self, timeout=45):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if self.process.poll() is not None:
                raise RuntimeError("Probe exited before readiness; see probe.log")
            try:
                self.evaluate("true", timeout=5)
                return
            except (RuntimeError, subprocess.TimeoutExpired):
                time.sleep(.25)
        raise TimeoutError("Probe did not become ready; see probe.log")

    def state(self):
        return json.loads(self.evaluate('const w=objc.send(objc.send("UIApplication","sharedApplication"),"windows")[0]; return objc.send(objc.send(w,"rootViewController"),"probeState");'))

    def tap(self, name):
        self.evaluate('await app.getByRole("button",{name:' + json.dumps(name) + ',exact:true}).tap();')

    def screenshot(self, name):
        subprocess.run([str(CLI), "screenshot", self.bundle, "-p", self.profile,
                        "-o", str(self.output / name)], check=True, capture_output=True, timeout=20)

    def close(self):
        if not self.started:
            return
        try:
            subprocess.run([str(CLI), "quit", self.bundle, "-p", self.profile],
                           capture_output=True, text=True, timeout=12)
        except subprocess.TimeoutExpired:
            # This is only our own `simrun run` controller. Closing its run
            # connection terminates its associated app, never the provider.
            if self.process.poll() is None:
                self.process.send_signal(signal.SIGINT)
        finally:
            if self.process.poll() is None:
                try:
                    self.process.wait(timeout=6)
                except subprocess.TimeoutExpired:
                    self.process.terminate()
                    self.process.wait(timeout=5)
            if self.log:
                self.log.close()
