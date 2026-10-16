#!/usr/bin/env python3
"""Check pre-capture metadata, source replacement, and actual frame dimensions."""
import argparse
import json
from pathlib import Path
import time

from PIL import Image
from acceptance_support import REPO, ProbeRun, save_json

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--image', required=True, type=Path)
parser.add_argument('--replacement', required=True, type=Path)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
out = args.output.resolve()
out.mkdir(parents=True, exist_ok=True)
images = [p.resolve(strict=True) for p in (args.image, args.replacement)]
sizes = [Image.open(p).size for p in images]
assert sizes[0] != sizes[1] and all(2 <= n <= 8192 and n % 2 == 0 for size in sizes for n in size)
for i, image in enumerate(images):
    save_json(out / f'camera-{i}.json', dict(devices=[dict(id='format-' + p, name=p, position=p,
        source=dict(kind='image', path=str(image))) for p in ('back', 'front')]))

run = ProbeRun(REPO / 'build/devices/DeviceProbe.app', 'dev.simrun.DeviceProbe',
               'camera-formats-20261016', out, REPO / 'build/devices/SimRunDevices.dylib')
checks = []
vc = 'objc.send(objc.send(objc.send("UIApplication","sharedApplication"),"windows")[0],"rootViewController")'

def check(name, passed, evidence):
    checks.append(dict(name=name, passed=bool(passed), evidence=evidence))
    save_json(out / 'results.json', dict(passed=all(c['passed'] for c in checks), checks=checks))
    assert passed, name
    print('PASS', name, flush=True)

def formats():
    return json.loads(run.evaluate(f'return objc.send({vc},"cameraFormats");'))

try:
    run.start(dict(SIMRUN_CAMERA_FILE=str(out / 'camera-0.json')))
    run.wait_ready()
    for i, (width, height) in enumerate(sizes):
        if i:
            run.evaluate(f'objc.send({vc},"stopCamera");')
            run.evaluate('return objc.send("SRSimRunCamera","configureFile:",' + json.dumps(str(out / 'camera-1.json')) + ');')
        deadline = time.monotonic() + 10
        while True:
            state = formats()
            if len(state) == 2 and all(s['width'] == height and s['height'] == width for s in state):
                break
            if time.monotonic() >= deadline:
                raise TimeoutError(f'format metadata not ready: {state}')
            time.sleep(.1)
        save_json(out / f'{i}-formats-before-capture.json', state)
        check(f'source {i}: both cameras have stable, listed native format before capture',
              all(s['formatCount'] == 1 and s['activeListed'] and s['identityStable'] and s['sRGB']
                  and s['fps'] == 5 and abs(s['duration'] - .2) < 1e-6 for s in state), state)
        before = run.state()['frames']
        run.evaluate(f'objc.send({vc},"startCamera");')
        deadline = time.monotonic() + 15
        while True:
            frame = run.state()
            if frame['frames'] > before + 2 and (frame['frameWidth'], frame['frameHeight']) == (width, height):
                break
            if time.monotonic() >= deadline:
                raise TimeoutError(f'frames did not match metadata: {frame}')
            time.sleep(.1)
        save_json(out / f'{i}-frames.json', frame)
        check(f'source {i}: portrait connection dimensions match delivered frames',
              all((s['height'], s['width']) == (frame['frameWidth'], frame['frameHeight']) for s in formats()), frame)
        starts = (out / 'probe.log').read_text().count('frame stream started for session')
        formats()
        time.sleep(.3)
        check(f'source {i}: discovery does not restart a running camera',
              starts == (out / 'probe.log').read_text().count('frame stream started for session'), starts)
except Exception as error:
    checks.append(dict(name='completed', passed=False, error=str(error)))
    save_json(out / 'results.json', dict(passed=False, checks=checks))
    raise
finally:
    run.close()
