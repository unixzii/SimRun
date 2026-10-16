#!/usr/bin/env python3
"""Read/write only an explicitly selected disposable probe's script context.

Does not launch, stop, rebuild or sign any App. Run after the fixed app.dylib is
bundled and a dedicated probe is running. Evidence contains no App logs.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import subprocess
import time
import uuid


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--simrun', type=Path, default=Path(__file__).resolve().parents[2] / 'build/bin/simrun')
    parser.add_argument('--pid', type=int, required=True)
    parser.add_argument('--profile', required=True)
    parser.add_argument('--bundle-id', required=True)
    parser.add_argument('--output', type=Path, default=Path(__file__).resolve().parents[2] / 'build/tests/objc-exceptions.json')
    args = parser.parse_args()
    if args.pid <= 0 or not args.profile or not args.bundle_id:
        parser.error('positive PID, explicit profile and bundle-id are required')
    marker = 'SCRIPT_EXCEPTION_VERIFY_' + uuid.uuid4().hex + ':'
    missing = 'simrun_missing_kvc_key_' + uuid.uuid4().hex
    guard = (
        'const bundle=objc.send(objc.send("NSBundle","mainBundle"),"bundleIdentifier");'
        'const info=objc.send("NSProcessInfo","processInfo");'
        'const pid=objc.send(info,"processIdentifier");'
        'const profile=objc.send(info,"environment").SIMRUN_PROFILE;'
        f'if(bundle!=={json.dumps(args.bundle_id)}||pid!=={args.pid}||profile!=={json.dumps(args.profile)})'
        'throw new Error("PROBE_IDENTITY_MISMATCH");'
    )
    report = {'schema':1, 'pid':args.pid, 'profile':args.profile,
              'bundle_id':args.bundle_id, 'started_at':time.time(), 'checks':[]}

    def evaluate(source: str, *, expect_failure: bool = False):
        run = subprocess.run([str(args.simrun.resolve()), 'eval', str(args.pid), '-p', args.profile,
                              guard + source], capture_output=True, text=True, timeout=20)
        if expect_failure:
            text = run.stdout + run.stderr
            if run.returncode != 1 or missing not in text or 'NSUnknownKeyException' not in text:
                raise AssertionError('uncaught native exception did not produce the expected CLI failure')
            return {'cli_exit':run.returncode, 'native_exception':'NSUnknownKeyException'}
        if run.returncode != 0:
            raise AssertionError('probe eval failed; private stdout/stderr omitted')
        rows = [line[len(marker):] for line in run.stdout.splitlines() if line.startswith(marker)]
        if len(rows) != 1:
            raise AssertionError('missing unique JSON result')
        return json.loads(rows[0])

    def emit(expression: str) -> str:
        return f'console.log({json.dumps(marker)}+JSON.stringify({expression}));'

    def check(name: str, function):
        item = {'name':name, 'started_at':time.time()}
        try:
            item['result'] = function()
            item['passed'] = True
        except Exception as exc:
            item.update(passed=False, error_type=type(exc).__name__)
        item['ended_at'] = time.time()
        report['checks'].append(item)
        print(name + ': ' + ('PASS' if item['passed'] else 'FAIL'))

    def identity():
        result = evaluate(emit('({pid,bundle,profile})'))
        assert result == {'pid':args.pid,'bundle':args.bundle_id,'profile':args.profile}
        return result

    check('bound_probe_identity', identity)
    if not report['checks'][-1]['passed']:
        report['skipped'] = 'Identity failed; no invalid KVC call was sent'
    else:
        def caught():
            source = (
                'let caught=false;'
                'try{objc.send(objc.send("NSObject","new"),"valueForKey:",'
                + json.dumps(missing) + ');}'
                'catch(error){caught=String(error).includes("NSUnknownKeyException")&&'
                'String(error).includes(' + json.dumps(missing) + ');}'
                'if(!caught)throw new Error("NATIVE_EXCEPTION_NOT_CATCHABLE");'
                + emit('({caught})')
            )
            result = evaluate(source)
            assert result == {'caught':True}
            return result
        check('native_exception_catchable_in_js', caught)
        check('uncaught_native_exception_cli_exit_1', lambda: evaluate(
            'objc.send(objc.send("NSObject","new"),"valueForKey:",'+json.dumps(missing)+');',
            expect_failure=True))
        check('same_pid_alive_after_both_errors', identity)

        def recovered():
            result = evaluate(emit('objc.send("NSString","stringWithString:","bridge-recovered")'))
            assert result == 'bridge-recovered'
            return {'legal_invocation':'ok'}
        check('subsequent_legal_invocation', recovered)
    report['passed'] = len(report['checks']) == 5 and all(x['passed'] for x in report['checks'])
    report['ended_at'] = time.time()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
    args.output.chmod(0o600)
    print('Evidence:',args.output.resolve())
    return 0 if report['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
