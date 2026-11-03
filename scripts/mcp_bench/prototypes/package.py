"""Assemble prototypes around an unchanged, already extracted distribution."""
import json
from pathlib import Path
import shutil

from external import digest


def assemble(candidate, toolchainManifest, docs, destination):
    dest = Path(destination)
    dest.mkdir(parents=True, exist_ok=True)
    source = Path(toolchainManifest['bundle'])
    shutil.copytree(source, dest / 'toolchain')
    for path in docs:
        shutil.copy2(path, dest / Path(path).name)
    root = Path(__file__).parent
    if candidate == 'python':
        shutil.copy2(root / 'external.py', dest / 'external.py')
    elif candidate == 'medaka':
        shutil.copy2(toolchainManifest['supervisor'], dest / 'supervisor')
    else:
        raise ValueError('unknown candidate')
    worker = dest / 'toolchain' / 'medaka'
    result = {'candidate': candidate, 'worker': str(worker.resolve()), 'sha256': digest(worker),
              'identity_provenance': 'inferred', 'matching': 'unavailable'}
    (dest / 'manifest.json').write_text(json.dumps(result, indent=2) + '\n')
    return result
