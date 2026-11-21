#!/usr/bin/env python3
"""Opt-in location-only invalid/missing configuration recovery in one Probe PID.

The test owns only its fresh profiles. It does not start camera capture, change
host privacy, or modify any user's App/container/settings file.
"""
import argparse
import json
from pathlib import Path
import time
import uuid
from acceptance_support import REPO, ProbeRun, save_json

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--app', type=Path, default=REPO/'build/devices/LocationProbe.app')
parser.add_argument('--dylib', type=Path, default=REPO/'build/devices/SimRunLocation.dylib')
parser.add_argument('--output', type=Path, default=REPO/'build/devices/acceptance/location-invalid')
args = parser.parse_args()
out = args.output.resolve(); out.mkdir(parents=True, exist_ok=True)
checks = []
completed = False
failure = None

def close_owned(run, app_pid):
    # Closing our long-lived run connection terminates only its associated App.
    # Never select a process to quit by a bundle/name/profile supplied externally.
    if run.process is not None:
        if run.process.poll() is None:
            run.process.terminate()
        run.process.wait(timeout=6)
    if run.log:
        run.log.close()
    if app_pid is not None:
        import subprocess
        deadline = time.monotonic() + 6
        while time.monotonic() < deadline:
            result = subprocess.run([str(REPO/'build/bin/simrun'), 'list'], capture_output=True, text=True, timeout=2)
            if result.returncode == 0 and not any(row.split() and row.split()[0] == str(app_pid) for row in result.stdout.splitlines()):
                return
            time.sleep(.1)
        raise AssertionError('Owned Probe PID was not reaped after closing its CLI')

def check(name, passed):
    checks.append({'name': name, 'passed': bool(passed)})
    if not passed:
        raise AssertionError(name)

def wait(getter, condition):
    deadline = time.monotonic() + 6
    while time.monotonic() < deadline:
        value = getter()
        if condition(value):
            return value
        time.sleep(.1)
    raise AssertionError('Expected configuration state did not arrive')

try:
    for initial in ('invalid', 'missing'):
        case = out/(initial+'-'+uuid.uuid4().hex[:8]); case.mkdir()
        fixture = case/'location.json'
        if initial == 'invalid':
            fixture.write_text('{invalid'); fixture.chmod(0o600)
        run = ProbeRun(args.app, 'dev.simrun.LocationProbe', 'location-invalid-'+uuid.uuid4().hex[:12], case, args.dylib)
        def label():
            # No location getter/request can drive refresh in this idle observation.
            return run.evaluate('const w=objc.send(objc.send("UIApplication","sharedApplication"),"windows")[0]; return objc.send(objc.send(objc.send(w,"rootViewController"),"status"),"text");')
        def valid():
            save_json(fixture, {'enabled': True, 'latitude': 31.2304, 'longitude': 121.4737,
                               'horizontalAccuracy': 5, 'authorization': 'authorizedWhenInUse'})
            fixture.chmod(0o600)
        pid = None
        try:
            run.start({'SIMRUN_LOCATION_FILE': str(fixture)}); run.wait_ready()
            pid = int(run.evaluate('objc.send(objc.send("NSProcessInfo","processInfo"),"processIdentifier")'))
            service = run.evaluate('objc.send("CLLocationManager","locationServicesEnabled")')
            state = run.state()
            check(initial+' initial disabled/denied/no cache', service == 'false' and state['authorization'] == 2 and not state['cachedLocationAvailable'])
            run.tap('Request location')
            denied = wait(run.state, lambda value: value.get('error') == 'kCLErrorDomain:1')
            check(initial+' request cannot emit native fix', denied['updates'] == 0)
            valid(); wait(label, lambda value: 'auth=4' in value)
            run.tap('Request location')
            fix = wait(run.state, lambda value: value['updates'] == 1)
            check(initial+' repaired file recovers through watcher', fix['latitude'] == 31.2304 and fix['longitude'] == 121.4737)
            broken = fixture.with_suffix('.broken'); broken.write_text('{invalid'); broken.replace(fixture)
            wait(label, lambda value: 'auth=2' in value)
            run.tap('Request location')
            denied_again = wait(run.state, lambda value: value.get('error') == 'kCLErrorDomain:1')
            check(initial+' dynamic invalid disables and clears exposed cache', denied_again['updates'] == 1 and not denied_again['cachedLocationAvailable'])
            valid(); wait(label, lambda value: 'auth=4' in value)
            run.tap('Request location')
            restored = wait(run.state, lambda value: value['updates'] == 2)
            same_pid = int(run.evaluate('objc.send(objc.send("NSProcessInfo","processInfo"),"processIdentifier")'))
            check(initial+' second recovery preserves PID', int(same_pid) == pid and restored['latitude'] == 31.2304)
            save_json(case/'states.json', {'pid': pid, 'cliPid': run.process.pid, 'initial': state, 'fix': fix, 'deniedAgain': denied_again, 'restored': restored})
        finally:
            close_owned(run, pid)
    completed = True
except BaseException as error:
    failure = type(error).__name__ + ': ' + str(error)
    raise
finally:
    save_json(out/'acceptance.json', {'checks': checks, 'completed': completed, 'failure': failure,
                                    'passed': completed and len(checks) == 10 and all(check['passed'] for check in checks),
                                    'scope': 'initial invalid/missing and repeated live file recovery; test-owned location-only Probes'})
