# Invalid location settings

An explicitly configured `SIMRUN_LOCATION_FILE` installs the process-local
adapter even if the initial file is missing or invalid. Services begin disabled,
authorization is denied and requests cannot fall through to native location.
The 250 ms watcher can restore a repaired valid file without restarting the App.

After building the location-only adapter and probe, run:

```sh
python3 extras/devices/tests/verify-location-invalid.py
```

The test covers both initial-invalid and initial-missing files. In the same
Probe PID it checks denied/no cache/no native fix, atomically installs valid
Shanghai configuration, waits for idle authorization UI propagation, requests a
fix, then repeats invalid/valid recovery. It uses fresh profiles and private
fixture files; camera and host location permissions are not exercised.
