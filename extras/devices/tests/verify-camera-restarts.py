#!/usr/bin/env python3
"""Real AVFoundation rapid-restart acceptance against an already running provider.

Run after other provider clients have stopped: this provider accepts one client.
Only this script's DeviceProbe profile is launched/stopped. It does not change
host privacy grants, provider settings, or any pre-existing application instance.
Use an explicit real-image configuration; screen capture is unsupported here.
"""
import argparse
from collections import Counter
import json
import os
from pathlib import Path
import re
import subprocess
import time

REPO = Path(__file__).resolve().parents[3]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--camera-config', required=True, type=Path)
parser.add_argument('--client-dylib', required=True, type=Path)
parser.add_argument('--rounds', type=int, default=50)
parser.add_argument('--visible', action='store_true', help='Show the test-owned Probe window')
parser.add_argument('--profile', default='camera-restart-stress')
args = parser.parse_args()
assert args.rounds > 0
config = args.camera_config.resolve(strict=True)
client = args.client_dylib.resolve(strict=True)
OUT = REPO / 'build/devices/acceptance/camera-restart-stress'
OUT.mkdir(parents=True, exist_ok=True)
CLI = str(REPO / 'build/bin/simrun')
APP = 'dev.simrun.DeviceProbe'
VC = 'objc.send(objc.send(objc.send("UIApplication","sharedApplication"),"windows")[0],"rootViewController")'
log_path = OUT / 'probe.log'
checks = []
log = log_path.open('w')
command = [CLI, 'run', '--mute', '-p', args.profile, '--insert', str(client)]
if not args.visible:
    command += ['--headless']
command += [str(REPO / 'build/devices/DeviceProbe.app')]
env = dict(os.environ, SIMRUN_CAMERA_FILE=str(config))
process = subprocess.Popen(command, cwd=REPO, env=env, stdout=log, stderr=subprocess.STDOUT)


def evaluate(script):
    response = subprocess.run([CLI, 'eval', APP, '-p', args.profile, script],
                              capture_output=True, text=True, timeout=15)
    if response.returncode:
        raise RuntimeError(response.stderr.strip())
    return response.stdout


def state():
    return json.loads(evaluate(f'objc.send({VC},"probeState")'))


def generations():
    content = log_path.read_text(errors='replace')
    starts = Counter(re.findall(r'frame stream started for session \d+ generation=(\d+) fd=\d+', content))
    closed = Counter(re.findall(r'frame stream closed session=\d+ generation=(\d+) fd=\d+ result=0', content))
    return content, starts, closed


def wait_until(predicate, timeout=15):
    deadline = time.monotonic() + timeout
    last_error = None
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError(f'probe exited unexpectedly: {process.returncode}')
        try:
            result = predicate()
            if result:
                return result
        except (RuntimeError, json.JSONDecodeError) as error:
            last_error = error
        time.sleep(0.05)
    raise TimeoutError(f'condition did not complete; last error: {last_error}')


def record(name, passed, **evidence):
    checks.append(dict(name=name, passed=bool(passed), **evidence))
    (OUT / 'results.json').write_text(json.dumps(dict(profile=args.profile, checks=checks), indent=2))
    if not passed:
        raise AssertionError(name)
    print('PASS', name, flush=True)


try:
    wait_until(lambda: evaluate('true').strip() == 'true', timeout=45)
    evaluate(f'objc.send({VC},"startCamera")')
    wait_until(lambda: state().get('frames', 0) >= 3, timeout=30)
    content, starts, closed = generations()
    record('new lifecycle diagnostics present', len(starts) == 1, starts=dict(starts))
    for round_number in range(args.rounds):
        before = state()['frames']
        expected_starts = len(starts) + 1
        # Both real controller actions execute in one main-thread turn, with no
        # artificial pause. startCamera opens a new AVCaptureSession normally.
        evaluate(f'const vc={VC}; objc.send(vc,"stopCamera"); objc.send(vc,"startCamera");')
        wait_until(lambda: len(generations()[1]) >= expected_starts)
        wait_until(lambda: state().get('frames', 0) >= before + 3)
        content, starts, closed = generations()
        record(f'rapid restart {round_number + 1}',
               'desynchronized' not in content and len(starts) == expected_starts,
               frames=state()['frames'], generations=len(starts))
    evaluate(f'objc.send({VC},"stopCamera")')
    wait_until(lambda: generations()[1] == generations()[2])
    content, starts, closed = generations()
    record('every generation closed exactly once',
           len(starts) == args.rounds + 1 and starts == closed and all(n == 1 for n in closed.values()),
           starts=dict(starts), closed=dict(closed))
    record('no parser or transport failure',
           'desynchronized' not in content and 'dropping undecodable' not in content
           and 'type=sessionInterrupted' not in content)
except Exception as error:
    checks.append(dict(name='run completed', passed=False, error=str(error)))
    (OUT / 'results.json').write_text(json.dumps(dict(profile=args.profile, checks=checks), indent=2))
    raise
finally:
    subprocess.run([CLI, 'quit', APP, '-p', args.profile], capture_output=True, timeout=15)
    try:
        process.wait(timeout=10)
    except subprocess.TimeoutExpired:
        process.terminate()
        process.wait(timeout=5)
    log.close()
