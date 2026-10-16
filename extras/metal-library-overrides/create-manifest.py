#!/usr/bin/env python3
"""Validate an explicit simulator Metal resource and write an opt-in mapping.

MIT License; Copyright (c) 2026 Cyandev. See LICENSE in this directory.
Never downloads, embeds, or publishes input libraries.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import struct
import subprocess
import tempfile

MAX_BYTES = 16 * 1024 * 1024


def read_library(path):
    with path.open('rb') as handle:
        data = handle.read(MAX_BYTES + 1)
    if not 24 <= len(data) <= MAX_BYTES or data[:4] != b'MTLB':
        raise ValueError('Expected a bounded MTLB library')
    if struct.unpack_from('<Q', data, 16)[0] != len(data):
        raise ValueError('MTLB declared length differs from file length')
    return data


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--input-library', required=True, type=Path)
    parser.add_argument('--simulator-library', required=True, type=Path)
    parser.add_argument('--manifest', required=True, type=Path)
    args = parser.parse_args()
    original = read_library(args.input_library)
    replacement = read_library(args.simulator_library)
    # Inspect the exact bytes being hashed, even if the caller's path changes
    # concurrently. The runtime will independently verify that same hash.
    with tempfile.TemporaryDirectory(prefix='simrun-metal-validate-') as temporary:
        inspected = Path(temporary) / 'replacement.metallib'
        inspected.write_bytes(replacement)
        ir = subprocess.check_output(['xcrun', 'metal-objdump', '--metallib', '--disassemble',
                                      str(inspected)], text=True, stderr=subprocess.PIPE)
    targets = sorted(set(re.findall(r'target triple = "([^"]+)"', ir)))
    functions = sorted(set(re.findall(r'source_filename = "([^"]+)"', ir)))
    if not targets or not functions or any(not re.fullmatch(r'air\d+(?:_v\d+)?-apple-ios[0-9.]+-simulator', item) for item in targets):
        raise ValueError('Every replacement AIR module must target iOS simulator')
    manifest = {'schema': 1, 'mappings': [{
        'input_sha256': hashlib.sha256(original).hexdigest(), 'input_size': len(original),
        'output_sha256': hashlib.sha256(replacement).hexdigest(), 'output_size': len(replacement),
        'output_path': str(args.simulator_library.resolve()),
        'validated_target_triples': targets,
    }]}
    args.manifest.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix='.metal-map-', dir=args.manifest.parent)
    try:
        with os.fdopen(descriptor, 'w') as handle:
            json.dump(manifest, handle, indent=2)
            handle.write('\n')
        os.replace(temporary, args.manifest)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    print(json.dumps({'ok': True, 'schema': 1, 'targets': targets,
                      'function_count': len(functions),
                      'input_sha256': manifest['mappings'][0]['input_sha256'],
                      'output_sha256': manifest['mappings'][0]['output_sha256']}))


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(json.dumps({'ok': False, 'error': str(error)}))
        raise SystemExit(1)
