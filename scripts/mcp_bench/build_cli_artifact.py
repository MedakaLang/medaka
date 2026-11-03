"""Build the benchmark's CLI-only distribution in a new pinned worktree."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

BASE = '0d10b7998'
ORIGINAL_SHA256 = '4b05aab61552d290a0e33d2b6f2f825290ecc61e24d9138f7fbaa829a19ee503'
SOURCE = 'compiler/driver/medaka_cli.mdk'


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def fingerprint(root):
    return {str(p.relative_to(root)): digest(p) for p in sorted(root.rglob('*')) if p.is_file()}


def build(repo, destination):
    repo, destination = Path(repo).resolve(), Path(destination).resolve()
    destination.mkdir(parents=True, exist_ok=False)
    tree, artifact = destination / 'source', destination / 'cli'
    base = subprocess.check_output(['git', '-C', str(repo), 'rev-parse', BASE], text=True).strip()
    subprocess.run(['git', 'clone', '--shared', '--no-checkout', str(repo), str(tree)], check=True)
    subprocess.run(['git', '-C', str(tree), 'checkout', '--detach', base], check=True)
    source = tree / SOURCE
    original = source.read_text()
    # Exclude the server module from the closure, rather than hide its executable name.
    changed = original.replace('import tools.mcp.{runMcpServer}\n', '')
    changed = changed[:changed.index('-- `mcp` takes no flags; same shape as `lspArgSpec`.')]
    changed += 'runMcpCmd : List String -> <IO> Unit\nrunMcpCmd _ = dieMsg "MCP unavailable in trial CLI artifact"\n'
    if changed == original or 'runMcpServer' in changed and 'import tools.mcp' in changed:
        raise RuntimeError('pinned source transformation did not match')
    source.write_text(changed)
    with (destination / 'build.log').open('w') as log:
        for verb in (['fmt', '--write'], ['lint']):
            subprocess.run([str(repo / 'medaka'), *verb, str(source)], stdout=log,
                           stderr=subprocess.STDOUT, check=True)
        subprocess.run(['make', '-C', str(tree), 'medaka'], stdout=log, stderr=subprocess.STDOUT, check=True)
    delta = subprocess.check_output(['git', '-C', str(tree), 'diff', '--name-only'], text=True).splitlines()
    if delta != [SOURCE]:
        raise RuntimeError(f'unexpected source delta: {delta}')
    (destination / 'source.patch').write_bytes(subprocess.check_output(['git', '-C', str(tree), 'diff', '--', SOURCE]))
    artifact.mkdir()
    for name in ('medaka', 'medaka_emitter'):
        shutil.copy2(tree / name, artifact / name)
    shutil.copytree(tree / 'stdlib', artifact / 'stdlib',
                    ignore=shutil.ignore_patterns('*.mdki', '*.mdkd', '*.mdke', '*.golden'))
    (artifact / 'runtime').mkdir()
    shutil.copy2(tree / 'runtime/medaka_rt.c', artifact / 'runtime/medaka_rt.c')
    manifest = {'base': base, 'source_delta': delta,
                'source_patch_sha256': digest(destination / 'source.patch'),
                'compiler_source_sha256': digest(source), 'files': fingerprint(artifact),
                'toolchain': {tool: subprocess.check_output([tool, '--version'], text=True).splitlines()[0]
                              for tool in ('clang', 'make', 'python3')},
                'source_fingerprint': (tree / '.medaka.srcstamp').read_text().strip()}
    (destination / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    return manifest


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('repo')
    parser.add_argument('destination', help='new scratch directory; preserved baseline is never edited')
    args = parser.parse_args()
    print(json.dumps(build(args.repo, args.destination)))
