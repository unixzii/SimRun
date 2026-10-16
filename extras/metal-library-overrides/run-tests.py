#!/usr/bin/env python3
"""Build/run only an owned short-lived headless simulator Metal regression probe.
MIT License; Copyright (c) 2026 Cyandev. See LICENSE in this directory.
Private libraries are supplied as explicit file arguments and are never copied into source.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import shutil
import time
import uuid

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--input-library', required=True, type=Path)
parser.add_argument('--simulator-library', required=True, type=Path)
parser.add_argument('--module', required=True, type=Path)
parser.add_argument('--expected-module-sha256', required=True)
parser.add_argument('--simrun', required=True, type=Path)
parser.add_argument('--output', required=True, type=Path)
args = parser.parse_args()
for name in ('input_library', 'simulator_library', 'module', 'simrun', 'output'):
    setattr(args, name, getattr(args, name).resolve())
module_hash = hashlib.sha256(args.module.read_bytes()).hexdigest()
if module_hash != args.expected_module_sha256:
    raise SystemExit('Module SHA256 differs from explicitly pinned reviewed build')
args.output.mkdir(mode=0o700, parents=True, exist_ok=False)
root = Path(__file__).resolve().parent
profile = 'metal-regression-' + uuid.uuid4().hex[:12]
exe = args.output / ('MetalOverrideProbe-' + uuid.uuid4().hex[:12])
manifest = args.output / 'valid-map.json'
commands = []
def checked(command):
    result = subprocess.run([str(x) for x in command], capture_output=True, text=True, timeout=90)
    commands.append({'command': [str(x) for x in command], 'returncode': result.returncode,
                     'stdout': result.stdout, 'stderr': result.stderr})
    if result.returncode:
        raise RuntimeError('Preparation command failed: ' + str(command[0]) + ': ' + result.stderr)
    return result
checked(['xcrun', '--sdk', 'iphonesimulator', 'clang', '-arch', 'arm64', '-target',
         'arm64-apple-ios17.0-simulator', '-fobjc-arc', '-fblocks', '-Wall', '-Wextra', '-Werror',
         root / 'tests.m', '-framework', 'Foundation', '-framework', 'Metal', '-o', exe])
checked(['codesign', '--force', '--sign', '-', exe])
checked(['python3', root / 'create-manifest.py', '--input-library', args.input_library,
         '--simulator-library', args.simulator_library, '--manifest', manifest])
env = dict(os.environ, SIMRUN_METAL_LIBRARY_MAP=str(manifest))
command = [str(args.simrun), 'run', '--headless', '-p', profile, '--insert', str(args.module),
           str(exe), str(args.input_library), str(args.simulator_library), str(manifest), str(args.output)]
started = time.monotonic()
process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env)
try:
    stdout, stderr = process.communicate(timeout=90)
except subprocess.TimeoutExpired:
    # Resolve only the unique executable/profile created above. Never stop the host or other Apps.
    cleanup = subprocess.run([str(args.simrun), 'quit', str(exe), '-p', profile],
                             capture_output=True, text=True, timeout=15)
    process.terminate()
    stdout, stderr = process.communicate(timeout=15)
    (args.output / 'timeout-cleanup.json').write_text(json.dumps({'returncode': cleanup.returncode,
        'stdout': cleanup.stdout, 'stderr': cleanup.stderr}, indent=2))
    raise RuntimeError('Owned probe timed out; scoped cleanup attempted')
finally:
    (args.output / 'commands.json').write_text(json.dumps(commands, indent=2))
(args.output / 'stdout.log').write_text(stdout)
(args.output / 'stderr.log').write_text(stderr)
start = stdout.find('{')
result = json.loads(stdout[start:])
result.update({'module_sha256': module_hash, 'profile': profile, 'process_exit_code': process.returncode,
               'elapsed_seconds': time.monotonic() - started, 'owned_process_exited': process.poll() is not None,
               'input_sha256': hashlib.sha256(args.input_library.read_bytes()).hexdigest(),
               'simulator_sha256': hashlib.sha256(args.simulator_library.read_bytes()).hexdigest()})
try:
    os.kill(result['pid'], 0)
    result['owned_probe_pid_gone'] = False
except ProcessLookupError:
    result['owned_probe_pid_gone'] = True
# Remove only this probe's disposable profile after confirming its actual PID exited.
profile_dir = Path.home() / 'Library/Developer/SimRun/data/Containers/Data/Profiles' / exe.name / profile
if result['owned_probe_pid_gone']:
    if profile_dir.exists():
        shutil.rmtree(profile_dir)
    try:
        profile_dir.parent.rmdir()
    except OSError:
        pass
result['owned_profile_removed'] = not profile_dir.exists()
(args.output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
for file in args.output.iterdir():
    file.chmod(0o700 if file == exe else 0o600)
print(json.dumps({'passed': result['passed'], 'checks': len(result['checks']),
                  'failed_count': result['failed_count'], 'exit_code': process.returncode,
                  'owned_process_exited': result['owned_process_exited'], 'result': str(args.output / 'result.json')}))
raise SystemExit(0 if result['passed'] and process.returncode == 0 and result['owned_probe_pid_gone'] and result['owned_profile_removed'] else 1)
