#!/usr/bin/env python3
"""No-inference ACP contract test against the production Swift launch plan.
Usage: python3 scripts/test_opencode_acp.py /absolute/path/to/pinned/opencode
Only loopback fixture requests are authorized; no provider credentials are used.
"""
import base64
import struct
import zlib
import http.server
import json
import os
from pathlib import Path
import queue
import subprocess
import sys
import tempfile
import threading
import time

requests = []
class Model(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        requests.append({'path': self.path, 'body': body, 'client': self.headers.get('X-ProxyPilot-Client'), 'session': self.headers.get('X-ProxyPilot-Session-ID'), 'auth': self.headers.get('Authorization') == 'Bearer pp_local_fixture'})
        assert self.path == '/v1/chat/completions', self.path
        assert body['model'] == 'proxypilot-active'
        messages = body['messages']
        last = messages[-1]
        text = str(last.get('content', ''))
        choice = None
        if last['role'] == 'user' and 'USE_MCP' in text:
            name = next(t['function']['name'] for t in body['tools'] if 'echo' in t['function']['name'])
            choice = (name, {'text': 'fixture-mcp-result'})
        elif last['role'] == 'user' and 'USE_BASH' in text:
            choice = ('bash', {'command': 'printf \"fixture-shell:%s\" \"$XDG_CONFIG_HOME\"', 'description': 'Run fixture shell'})
        if 'CANCEL_ME' in text: time.sleep(3)
        message = {'role': 'assistant', 'content': 'fixture-complete'}
        finish = 'stop'
        if choice:
            message = {'role': 'assistant', 'content': None, 'tool_calls': [{'id': 'call_fixture', 'type': 'function', 'function': {'name': choice[0], 'arguments': json.dumps(choice[1])}}]}
            finish = 'tool_calls'
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream' if body.get('stream') else 'application/json')
        self.end_headers()
        try:
            if body.get('stream'):
                chunks = [{'id': 'fixture', 'object': 'chat.completion.chunk', 'choices': [{'index': 0, 'delta': message, 'finish_reason': None}]}, {'id': 'fixture', 'object': 'chat.completion.chunk', 'choices': [{'index': 0, 'delta': {}, 'finish_reason': finish}], 'usage': {'prompt_tokens': 100, 'completion_tokens': 5, 'total_tokens': 105}}]
                for chunk in chunks: self.wfile.write(('data: '+json.dumps(chunk)+'\n\n').encode())
                self.wfile.write(b'data: [DONE]\n\n')
            else: self.wfile.write(json.dumps({'id': 'fixture', 'choices': [{'index': 0, 'message': message, 'finish_reason': finish}], 'usage': {'prompt_tokens': 100, 'completion_tokens': 5}}).encode())
        except BrokenPipeError: pass

class MCP(http.server.BaseHTTPRequestHandler):
    calls = 0
    def log_message(self, *args): pass
    def do_POST(self):
        req = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        method = req.get('method')
        if 'id' not in req:
            self.send_response(202); self.end_headers(); return
        result = {'protocolVersion': '2024-11-05', 'capabilities': {'tools': {}}, 'serverInfo': {'name': 'fixture', 'version': '1'}}
        if method == 'tools/list': result = {'tools': [{'name': 'echo', 'description': 'Fixture echo', 'inputSchema': {'type': 'object', 'properties': {'text': {'type': 'string'}}, 'required': ['text']}}]}
        if method == 'tools/call':
            MCP.calls += 1
            result = {'content': [{'type': 'text', 'text': req['params']['arguments']['text']}]}
        data = json.dumps({'jsonrpc': '2.0', 'id': req['id'], 'result': result}).encode()
        self.send_response(200); self.send_header('Content-Type', 'application/json'); self.send_header('Content-Length', str(len(data))); self.end_headers(); self.wfile.write(data)

class ACP:
    def __init__(self, plan, cwd):
        self.p = subprocess.Popen(plan['arguments'], executable=plan['executable'], env=plan['environment'], cwd=cwd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.q = queue.Queue(); self.events = []; self.permission = 'reject_once'; self.next_id = 0; self.errors = []
        def read(stream, target):
            for line in stream:
                try: target(json.loads(line))
                except json.JSONDecodeError: self.errors.append(line[:500])
        threading.Thread(target=read, args=(self.p.stdout, self.q.put), daemon=True).start()
        threading.Thread(target=lambda: [self.errors.append(line.strip()) for line in self.p.stderr], daemon=True).start()
    def send(self, obj): self.p.stdin.write(json.dumps(obj)+'\n'); self.p.stdin.flush()
    def start(self, method, params):
        self.next_id += 1; self.send({'jsonrpc': '2.0', 'id': self.next_id, 'method': method, 'params': params}); return self.next_id
    def result(self, ident):
        deadline = time.time()+45
        while time.time() < deadline:
            try: obj = self.q.get(timeout=1)
            except queue.Empty:
                if self.p.poll() is not None: raise RuntimeError(self.errors)
                continue
            if obj.get('id') == ident and 'method' not in obj:
                assert 'error' not in obj, (obj, self.errors[-10:], [(str(p), p.read_text()[-5000:]) for p in root.rglob('*.log')])
                return obj['result']
            self.events.append(obj)
            if obj.get('method') == 'session/request_permission':
                self.send({'jsonrpc': '2.0', 'id': obj['id'], 'result': {'outcome': {'outcome': 'selected', 'optionId': next(o['optionId'] for o in obj['params']['options'] if o['kind'] == self.permission)}}})
            elif 'id' in obj and 'method' in obj:
                self.send({'jsonrpc': '2.0', 'id': obj['id'], 'error': {'code': -32601, 'message': 'Fixture has no client filesystem/terminal delegation'}})
        raise TimeoutError((ident, self.errors[-5:], self.events[-3:]))
    def call(self, method, params): return self.result(self.start(method, params))
    def close(self):
        self.p.terminate()
        try: self.p.wait(timeout=5)
        except subprocess.TimeoutExpired: self.p.kill(); self.p.wait()

with tempfile.TemporaryDirectory(prefix='pp-acp-contract-') as directory:
    root = Path(directory); (root/'repo').mkdir()
    model = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Model)
    mcp = http.server.ThreadingHTTPServer(('127.0.0.1', 0), MCP)
    for server in [model, mcp]: threading.Thread(target=server.serve_forever, daemon=True).start()
    env = dict(os.environ, PROXYPILOT_ACP_FIXTURE_ROOT=directory, PROXYPILOT_ACP_FIXTURE_ENGINE=str(Path(sys.argv[1]).resolve()), PROXYPILOT_ACP_FIXTURE_PORT=str(model.server_port))
    subprocess.run(['swift', 'test', '--package-path', 'ProxyPilotCore', '--filter', 'exportOpenCodeACPFixturePlan'], env=env, check=True, stdout=subprocess.DEVNULL)
    plan = json.loads((root/'plan.json').read_text())
    session_params = {'cwd': str(root/'repo'), 'mcpServers': [{'type': 'http', 'name': 'fixture', 'url': f'http://127.0.0.1:{mcp.server_port}', 'headers': []}]}
    init = {'protocolVersion': 1, 'clientCapabilities': {}}
    acp = ACP(plan, root/'repo')
    try:
        assert acp.call('initialize', init)['agentInfo']['version'] == '1.18.4'
        sid = acp.call('session/new', session_params)['sessionId']
        def prompt(text, extra=None):
            return acp.call('session/prompt', {'sessionId': sid, 'prompt': [{'type': 'text', 'text': text}] + (extra or [])})
        assert prompt('USE_MCP')['stopReason'] == 'end_turn'
        assert MCP.calls == 1, ('No MCP call', requests)
        assert any(m['role'] == 'tool' for m in requests[-1]['body']['messages'])
        stable = {k: requests[-1]['body'].get(k) for k in ['tools']}
        system = [m for m in requests[-1]['body']['messages'] if m['role'] == 'system']
        assert prompt('SECOND_TURN')['stopReason'] == 'end_turn'
        assert requests[-1]['body']['tools'] == stable['tools']
        assert [m for m in requests[-1]['body']['messages'] if m['role'] == 'system'] == system
        assert prompt('USE_BASH')['stopReason'] == 'end_turn'
        acp.permission = 'allow_once'
        assert prompt('USE_BASH_ALLOW')['stopReason'] == 'end_turn'
        assert 'fixture-shell:' + str(root/'user-config') in str(requests[-1]['body']['messages'][-1]['content']), requests[-1]['body']['messages'][-1]
        assert any(e.get('method') == 'session/request_permission' for e in acp.events)
        def chunk(kind, data):
            return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
        png = base64.b64encode(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 16, 16, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress((b'\0' + b'\xff\0\0' * 16) * 16)) + chunk(b'IEND', b'')).decode()
        assert prompt('IMAGE_TURN', [{'type': 'image', 'mimeType': 'image/png', 'data': png}])['stopReason'] == 'end_turn'
        assert 'image_url' in json.dumps(requests[-1]['body']['messages'])
        pending = acp.start('session/prompt', {'sessionId': sid, 'prompt': [{'type': 'text', 'text': 'CANCEL_ME'}]})
        time.sleep(.4); acp.send({'jsonrpc': '2.0', 'method': 'session/cancel', 'params': {'sessionId': sid}})
        assert acp.result(pending)['stopReason'] == 'cancelled'
        original_id = requests[0]['session']
    finally: acp.close()
    acp = ACP(plan, root/'repo')
    try:
        acp.call('initialize', init)
        acp.call('session/load', dict(session_params, sessionId=sid))
        assert acp.call('session/prompt', {'sessionId': sid, 'prompt': [{'type': 'text', 'text': 'RESUMED_TURN'}]})['stopReason'] == 'end_turn'
        assert requests[-1]['session'] == original_id
        assert 'SECOND_TURN' in json.dumps(requests[-1]['body']['messages'])
        assert all(r['client'] == 'xcode-agent' and r['auth'] for r in requests)
        assert all('x-anthropic-billing-header' not in json.dumps(r['body']) for r in requests)
        receipt = {'engine': '1.18.4', 'model_requests': len(requests), 'checks': ['initialize', 'session/new', 'editor MCP tool call', 'tool result replay', 'stable system/tools across append', 'permission denial and approval', 'shell XDG restoration', 'image forwarding', 'cancellation', 'cross-process session/load', 'stable session attribution', 'local authentication', 'no Claude billing header'], 'scope': 'Local model and MCP fixtures only. No Xcode UI or provider cache acceptance.'}
        print(json.dumps(receipt, indent=2))
        if os.environ.get('PROXYPILOT_ACP_RECEIPT'): Path(os.environ['PROXYPILOT_ACP_RECEIPT']).write_text(json.dumps(receipt, indent=2)+'\n')
    finally: acp.close(); model.shutdown(); mcp.shutdown()
