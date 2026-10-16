#!/usr/bin/env python3
"""Opt-in runtime check: App camera allowed, host Screen Recording denied.

Requires the actual host permission to already be off and a running provider.
Never toggles System Settings and never treats this as live-screen acceptance.
Uses a visible own-profile Probe, then closes it on every exit path.
"""
import argparse
from pathlib import Path
import time,uuid
from acceptance_support import REPO,ProbeRun,save_json

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--expect-host-denied',required=True,action='store_true')
parser.add_argument('--output',type=Path,default=REPO/'build/devices/acceptance/screen-host-denial')
args=parser.parse_args()
out=args.output.resolve();out.mkdir(parents=True,exist_ok=True)
config=out/'camera.json'
save_json(config,{'name':'Host permission gate','authorization':'authorized','devices':[{'id':'desktop-back','name':'Desktop back','position':'back','source':{'kind':'screen'}}]})
run=ProbeRun(REPO/'build/devices/DeviceProbe.app','dev.simrun.DeviceProbe','screen-host-denial-'+uuid.uuid4().hex[:8],out,REPO/'build/devices/SimRunDevices.dylib')
checks=[]
report={'scope':'actual screen session with host permission denied; not successful live capture','checks':checks}
def check(name,value):
 checks.append({'name':name,'passed':bool(value)})
 save_json(out/'acceptance.json',report)
 if not value: raise AssertionError(name)
 print('PASS',name,flush=True)
try:
 run.start({'SIMRUN_CAMERA_FILE':str(config)},headless=False)
 run.wait_ready()
 run.tap('Start camera')
 deadline=time.monotonic()+15
 while time.monotonic()<deadline:
  state=run.state()
  log=(out/'probe.log').read_text(errors='replace')
  if state['frames']>0: raise AssertionError('Host appears authorized; denied-path expectation is no longer valid')
  if 'type=sessionInterrupted' in log and not state['cameraRunning']: break
  time.sleep(.1)
 else: raise TimeoutError('No interrupted session observed')
 save_json(out/'01-interrupted.json',state)
 check('App camera authorized while host screen source interrupts',state['cameraAuthorization']==3 and state['cameraAllowed'] and not state['cameraRunning'])
 time.sleep(1.3);stable=run.state();save_json(out/'02-no-frames.json',stable)
 check('host denial emits zero screen or placeholder frames',stable['frames']==state['frames']==0)
 run.tap('Take photo')
 deadline=time.monotonic()+8
 while time.monotonic()<deadline:
  failed=run.state()
  if failed['completions']>=1: break
  time.sleep(.1)
 time.sleep(.4);failed=run.state();save_json(out/'03-no-photo.json',failed)
 check('photo fails once without old image',failed['photos']==0 and failed['processingCallbacks']==1 and failed['completions']==1 and failed['photoErrors']==1 and failed.get('lastPhotoErrorHadImage') is False)
 check('failure is reported through AVFoundation',failed.get('lastPhotoErrorDomain')=='AVFoundationErrorDomain')
 report['passed']=True
 save_json(out/'acceptance.json',report)
except BaseException as error:
 report['passed']=False;report['failure']=str(error);save_json(out/'acceptance.json',report)
 raise
finally: run.close()
