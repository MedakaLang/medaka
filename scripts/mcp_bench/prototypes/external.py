"""Python supervisor experiment; semantic operations are delegated to MCP."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


class Worker:
    def __init__(self, artifact, root):
        path = artifact['path']
        actual = digest(path)
        if actual != artifact['digest']:
            raise ValueError('artifact digest mismatch')
        self.identity = artifact['id']
        self.hash = actual
        self.log = tempfile.TemporaryFile(mode='w+')
        try:
            self.process = subprocess.Popen([path, 'mcp'], cwd=root, stdin=subprocess.PIPE,
                                            stdout=subprocess.PIPE, stderr=self.log, text=True)
        except Exception:
            self.log.close()
            raise
        try:
            reply = self.call({'jsonrpc': '2.0', 'id': 0, 'method': 'initialize',
                               'params': {'protocolVersion': '2024-11-05', 'capabilities': {},
                                          'clientInfo': {'name': 'prototype', 'version': '1'}}})
            if reply.get('result', {}).get('protocolVersion') != '2024-11-05':
                raise ValueError('incompatible MCP version')
        except Exception:
            self.close()
            raise

    def call(self, message):
        if self.process.poll() is not None:
            raise RuntimeError('worker exited')
        self.process.stdin.write(json.dumps(message) + '\n')
        self.process.stdin.flush()
        line = self.process.stdout.readline()
        if not line:
            raise RuntimeError('worker exited')
        return json.loads(line)

    def close(self):
        if self.process.poll() is None:
            self.process.stdin.close()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
        else:
            self.process.stdin.close()
        self.process.stdout.close()
        self.log.close()


class Supervisor:
    def __init__(self):
        self.workspaces = {}

    def open(self, name, root, artifact):
        if name in self.workspaces:
            raise ValueError('duplicate workspace')
        worker = Worker(artifact, os.path.realpath(root))
        self.workspaces[name] = (os.path.realpath(root), worker)
        return self.status(name)

    def status(self, name):
        _, worker = self.workspaces[name]
        return {'ready': worker.process.poll() is None, 'worker': worker.identity, 'pid': worker.process.pid,
                'toolchain': {'value': worker.hash, 'provenance': 'inferred'},
                'attestation': {'value': None, 'provenance': 'unavailable'},
                'matching': 'unavailable', 'profile': {'value': None, 'provenance': 'unavailable'}}

    def check(self, name, request_id, arguments):
        root, worker = self.workspaces[name]
        data = arguments['source'].encode() if 'source' in arguments else (Path(root) / arguments['file']).read_bytes()
        reply = worker.call({'jsonrpc': '2.0', 'id': request_id, 'method': 'tools/call',
                             'params': {'name': 'medaka_check', 'arguments': arguments}})
        return {'semantic': reply, 'snapshot': {'value': hashlib.sha256(data).hexdigest(), 'provenance': 'inferred'},
                'profile': {'value': None, 'provenance': 'unavailable'}}

    def replace(self, name, artifact):
        root, old = self.workspaces[name]
        candidate = Worker(artifact, root)
        self.workspaces[name] = (root, candidate)
        old.close()
        return self.status(name)

    def close(self):
        for _, worker in self.workspaces.values():
            worker.close()
        self.workspaces.clear()


def main(argv):
    supervisor = Supervisor()
    ready = False
    seen = set()
    try:
        for line in sys.stdin:
            msg = json.loads(line)
            kind = msg.get('type')
            if kind == 'initialize':
                ready = 1 in msg['versions']
                result = {'type': 'initialized', 'version': 1 if ready else None,
                          'capabilities': ['check'] if ready else [],
                          'worker': 'supervisor' if ready else None,
                          'error': None if ready else 'incompatible'}
                print(json.dumps(result), flush=True)
                if not ready:
                    break
                continue
            if kind == 'shutdown':
                break
            request_id = msg.get('id')
            try:
                if not ready or not request_id or request_id in seen:
                    raise ValueError('invalid or duplicate request')
                seen.add(request_id)
                if kind == 'request':
                    name = msg['context']['workspace']['value']
                    op = msg['operation']
                    args = op['arguments']
                    if op['name'] == 'openWorkspace':
                        artifact = dict(args['artifact'], path=args['artifact']['id'])
                        value = supervisor.open(name, args['root'], artifact)
                    elif op['name'] == 'status':
                        value = supervisor.status(name)
                    elif op['name'] == 'check':
                        value = supervisor.check(name, request_id, args)
                    else:
                        raise ValueError('unknown operation')
                    result = {'type': 'response', 'id': request_id, 'status': 'complete', 'result': value, 'error': None}
                elif kind == 'replace':
                    name = msg['workspace']
                    old = supervisor.status(name)['worker']
                    try:
                        artifact = dict(msg['artifact'], path=msg['artifact']['id'])
                        supervisor.replace(name, artifact)
                        result = {'type': 'replacement', 'id': request_id, 'workspace': name, 'status': 'switched', 'worker': artifact['id'], 'error': None}
                    except (OSError, ValueError, RuntimeError, BrokenPipeError) as error:
                        result = {'type': 'replacement', 'id': request_id, 'workspace': name, 'status': 'failed', 'worker': old, 'error': str(error)}
                else:
                    raise ValueError('unknown message')
            except (OSError, ValueError, KeyError, RuntimeError, BrokenPipeError) as error:
                result = {'type': 'response', 'id': request_id, 'status': 'error', 'result': None, 'error': str(error)}
            print(json.dumps(result), flush=True)
    finally:
        supervisor.close()
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
