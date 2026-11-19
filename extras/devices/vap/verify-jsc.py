#!/usr/bin/env python3
"""Run isolated JSC VM creation cases without touching business app instances."""
import json
import pathlib
import subprocess
import time
import uuid

ROOT = pathlib.Path(__file__).resolve().parents[3]
OUT = ROOT / 'build/vap'
CLI = ROOT / 'build/bin/simrun'
APP = OUT / 'JSCProbe.app'
cases = []
for parallel, with_eval in [(False, False), (False, True), (True, False), (True, True)]:
    name = ('parallel' if parallel else 'serial') + ('-eval' if with_eval else '-no-eval')
    profile = 'jsc-isolated-' + name + '-' + uuid.uuid4().hex[:8]
    log = OUT / ('jsc-' + name + '.log')
    command = [str(CLI), 'run', '--headless', '--mute', '-p', profile, str(APP)]
    if parallel:
        command += ['--parallel']
    case = {'case': name, 'profile': profile, 'evalRequested': with_eval}
    with log.open('w') as output:
        process = subprocess.Popen(command, cwd=ROOT, stdout=output, stderr=subprocess.STDOUT)
        deadline = time.monotonic() + 90
        evaluated = False
        try:
            while time.monotonic() < deadline:
                content = log.read_text(errors='replace')
                if with_eval and not evaluated and 'JSC_READY' in content:
                    response = subprocess.run([str(CLI), 'eval', 'dev.simrun.JSCStressProbe', '-p', profile, '1+1'],
                                              cwd=ROOT, capture_output=True, text=True, timeout=10)
                    case['evalExit'] = response.returncode
                    case['evalResult'] = response.stdout.strip()
                    evaluated = True
                    # Completion must precede JSC_START to count as a clean prewarm.
                    case['evalBeforeStress'] = 'JSC_START' not in log.read_text(errors='replace')
                for line in content.splitlines():
                    if line.startswith('JSC_RESULT '):
                        case['result'] = json.loads(line[len('JSC_RESULT '):])
                if 'result' in case:
                    break
                if process.poll() is not None:
                    case['unexpectedExit'] = process.returncode
                    break
                time.sleep(0.1)
            if 'result' not in case and 'unexpectedExit' not in case:
                case['timeout'] = True
        finally:
            subprocess.run([str(CLI), 'quit', 'dev.simrun.JSCStressProbe', '-p', profile],
                           cwd=ROOT, capture_output=True, timeout=10)
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.terminate()
                process.wait(timeout=5)
    result = case.get('result', {})
    expected = 400 if parallel else 100
    case['passed'] = (result.get('passed') == expected and result.get('failed') == 0
                      and result.get('mainResult') == 42 and result.get('complete') is True
                      and result.get('peakWorkers') == (4 if parallel else 1)
                      and (not with_eval or (case.get('evalExit') == 0 and case.get('evalBeforeStress'))))
    cases.append(case)
    print(json.dumps(case), flush=True)
    (OUT / 'jsc-results.json').write_text(json.dumps(cases, indent=2) + '\n')
raise SystemExit(0 if all(case['passed'] for case in cases) else 1)
