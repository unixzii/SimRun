#!/usr/bin/env python3
"""Verify location settings reach an idle App and an active CLLocationManager."""
import argparse,json,time,uuid
from pathlib import Path
from acceptance_support import REPO,ProbeRun,save_json

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--dylib',type=Path,default=REPO/'build/devices/SimRunLocation.dylib')
parser.add_argument('--output',type=Path,default=REPO/'build/devices/acceptance/location-settings')
parser.add_argument('--app',type=Path,default=REPO/'build/devices/LocationProbe.app')
parser.add_argument('--bundle',default='dev.simrun.LocationProbe')
args=parser.parse_args();out=args.output.resolve();out.mkdir(parents=True,exist_ok=True)
config={'name':'Shanghai (simulated)','latitude':31.2304,'longitude':121.4737,'horizontalAccuracy':5,'enabled':True,'authorization':'notDetermined','requestAuthorization':'authorizedWhenInUse'}
path=out/'location.json'
def configure(**changes):
 config.update(changes);save_json(path,config);path.chmod(0o600)
configure()
run=ProbeRun(args.app,args.bundle,'location-settings-'+uuid.uuid4().hex[:8],out,args.dylib)
checks=[];report={'checks':checks,'scope':'idle authorization delegate propagation and live simulated Shanghai coordinates'}
def check(name,value):
 checks.append({'name':name,'passed':bool(value)})
 if not value:raise AssertionError(name)
 print('PASS',name,flush=True)
def wait(getter,test,timeout=6):
 deadline=time.monotonic()+timeout
 while time.monotonic()<deadline:
  result=getter()
  if test(result):return result
  time.sleep(.1)
 raise AssertionError('Expected state absent: '+str(result))
def label():
 # Reading the label does not call probeState/updateStatus: only the location
 # delegate can refresh this idle UI after the config file changes.
 return run.evaluate('const w=objc.send(objc.send("UIApplication","sharedApplication"),"windows")[0]; return objc.send(objc.send(objc.send(w,"rootViewController"),"status"),"text");')
try:
 run.start({'SIMRUN_LOCATION_FILE':str(path)});run.wait_ready()
 check('location starts undetermined',run.state()['authorization']==0)
 configure(authorization='denied');denied_label=wait(label,lambda s:'auth=2' in s)
 save_json(out/'01-idle-denied.json',{'label':denied_label,'state':run.state()})
 check('settings denial updates idle App through delegate',run.state()['authorization']==2 and run.state()['updates']==0)
 configure(authorization='authorizedAlways');wait(label,lambda s:'auth=3' in s)
 check('settings always authorization updates idle App',run.state()['authorization']==3)
 configure(enabled=False);wait(label,lambda s:'auth=2' in s)
 check('location services off reaches idle App',run.state()['authorization']==2)
 configure(enabled=True,authorization='authorizedWhenInUse');wait(label,lambda s:'auth=4' in s)
 run.tap('Request location');first=wait(run.state,lambda s:s['updates']==1)
 check('Shanghai one-shot returns configured WGS84 and accuracy',first['latitude']==31.2304 and first['longitude']==121.4737 and first['accuracy']==5)
 run.tap('Start location');wait(run.state,lambda s:s['updates']>=2)
 configure(latitude=31.22046,longitude=121.45801);changed=wait(run.state,lambda s:s.get('latitude')==31.22046 and s.get('longitude')==121.45801)
 check('active App follows edited coordinates',changed['timestamp']>first['timestamp'])
 run.tap('Stop location');stopped=run.state();configure(latitude=31.2304,longitude=121.4737);time.sleep(1.3)
 check('editing coordinates does not restart stopped updates',run.state()['updates']==stopped['updates'])
 configure(authorization='denied');wait(label,lambda s:'auth=2' in s);run.tap('Request location');denied=wait(run.state,lambda s:s.get('error')=='kCLErrorDomain:1')
 check('denied request returns no fix or cached location',denied['updates']==stopped['updates'] and not denied['cachedLocationAvailable'])
 configure(authorization='authorizedWhenInUse');wait(label,lambda s:'auth=4' in s);run.tap('Request location');restored=wait(run.state,lambda s:s['updates']==stopped['updates']+1)
 check('explicit restore returns Shanghai again',restored['latitude']==31.2304 and restored['longitude']==121.4737)
 report['passed']=True;report['finalState']=restored
except BaseException as error:
 report['passed']=False;report['failure']=str(error);raise
finally:
 save_json(out/'acceptance.json',report);run.close()
