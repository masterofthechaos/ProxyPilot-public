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
        if last['role'] == 'user' and ('USE_MCP' in text or 'HOLD_MCP' in text):
            name = next(t['function']['name'] for t in body['tools'] if 'echo' in t['function']['name'])
            choice = (name, {'text': 'hold-fixture' if 'HOLD_MCP' in text else 'fixture-mcp-result'})
        elif last['role'] == 'user' and 'USE_BASH' in text:
            choice = ('bash', {'command': 'printf \"fixture-shell:%s\" \"$XDG_CONFIG_HOME\"', 'description': 'Run fixture shell'})
        elif last['role'] == 'user' and 'REQUEST_CHILD_TASK' in text:
            choice = ('task', {
                'description': 'Check child approval handling',
                'prompt': 'USE_BASH',
                'subagent_type': 'general',
            })
        if 'CANCEL_ME' in text: time.sleep(3)
        message = {'role': 'assistant', 'content': 'fixture-complete'}
        finish = 'stop'
        if choice:
            message = {'role': 'assistant', 'content': None, 'tool_calls': [{'id': f'call_fixture_{len(requests)}', 'type': 'function', 'function': {'name': choice[0], 'arguments': json.dumps(choice[1])}}]}
            finish = 'tool_calls'
        try:
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream' if body.get('stream') else 'application/json')
            self.end_headers()
            if body.get('stream'):
                chunks = [{'id': 'fixture', 'object': 'chat.completion.chunk', 'choices': [{'index': 0, 'delta': message, 'finish_reason': None}]}, {'id': 'fixture', 'object': 'chat.completion.chunk', 'choices': [{'index': 0, 'delta': {}, 'finish_reason': finish}], 'usage': {'prompt_tokens': 100, 'completion_tokens': 5, 'total_tokens': 105}}]
                for chunk in chunks: self.wfile.write(('data: '+json.dumps(chunk)+'\n\n').encode())
                self.wfile.write(b'data: [DONE]\n\n')
            else: self.wfile.write(json.dumps({'id': 'fixture', 'choices': [{'index': 0, 'message': message, 'finish_reason': finish}], 'usage': {'prompt_tokens': 100, 'completion_tokens': 5}}).encode())
        except BrokenPipeError: pass

class MCP(http.server.BaseHTTPRequestHandler):
    calls = 0
    waiting = threading.Event()
    release = threading.Event()
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
            if req['params']['arguments']['text'] == 'hold-fixture':
                MCP.waiting.set()
                MCP.release.wait(timeout=15)
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
    def result(self, ident, timeout=45, expected_error=None):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try: obj = self.q.get(timeout=1)
            except queue.Empty:
                if self.p.poll() is not None: raise RuntimeError(self.errors)
                continue
            if obj.get('id') == ident and 'method' not in obj:
                if expected_error is not None:
                    assert 'error' in obj and expected_error in json.dumps(obj['error']), obj
                    return obj['error']
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
        # A synthetic model may request a tool even when it was omitted from
        # the advertised schema. The engine must resolve this turn either way.
        child_attempt = acp.start('session/prompt', {
            'sessionId': sid,
            'prompt': [{'type': 'text', 'text': 'REQUEST_CHILD_TASK'}],
        })
        try:
            assert acp.result(child_attempt, timeout=10)['stopReason'] == 'end_turn'
        except TimeoutError as error:
            raise AssertionError('Child task left the ACP turn waiting for approval') from error
        assert prompt('AFTER_CHILD_TASK')['stopReason'] == 'end_turn'
        child_request = next(
            request['body'] for request in requests
            if 'REQUEST_CHILD_TASK' in str(request['body']['messages'][-1].get('content', ''))
        )
        assert all(tool['function']['name'] != 'task' for tool in child_request['tools'])
        assert len({request['session'] for request in requests}) == 1
        review = acp.start('session/prompt', {
            'sessionId': sid,
            'prompt': [{'type': 'text', 'text': '/review'}],
        })
        # The engine converts command-hook errors into a generic ACP service error.
        acp.result(review, timeout=10, expected_error='OpenCode service failure')
        assert prompt('AFTER_REVIEW_REFUSAL')['stopReason'] == 'end_turn'
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
        trace_path = root / 'profile/data/opencode/log/proxypilot-lifecycle.log'
        trace = [json.loads(line) for line in trace_path.read_text().splitlines()]
        for start, end in [('tool_started', 'tool_finished'), ('approval_requested', 'approval_resolved')]:
            started = {row['correlationID'] for row in trace if row['event'] == start}
            finished = {row['correlationID'] for row in trace if row['event'] == end}
            assert started & finished, (start, end, [row['event'] for row in trace])
        assert any(row['sessionID'] == original_id for row in trace)
        assert 'fixture-shell' not in trace_path.read_text()
        assert 'fixture-mcp-result' not in trace_path.read_text()
        assert all(r['client'] == 'xcode-agent' and r['auth'] for r in requests)
        assert all('x-anthropic-billing-header' not in json.dumps(r['body']) for r in requests)
        receipt = {'engine': '1.18.4', 'model_requests': len(requests), 'checks': ['initialize', 'session/new', 'editor MCP tool call', 'tool result replay', 'stable system/tools across append', 'permission denial and approval', 'shell XDG restoration', 'image forwarding', 'cancellation', 'cross-process session/load', 'stable session attribution', 'local authentication', 'no Claude billing header'], 'scope': 'Local model and MCP fixtures only. No Xcode UI or provider cache acceptance.'}
        receipt['checks'].append('model-started child task refusal and next-turn recovery')
        receipt['checks'].append('metadata-only tool and approval lifecycle')
        receipt['checks'].append('built-in review refusal and next-turn recovery')
        blocked = acp.start('session/prompt', {
            'sessionId': sid,
            'prompt': [{'type': 'text', 'text': 'HOLD_MCP'}],
        })
        assert MCP.waiting.wait(timeout=10), 'Fixture editor tool never received the call'
        pending_trace = [json.loads(line) for line in trace_path.read_text().splitlines()]
        completed = {row['correlationID'] for row in pending_trace if row['event'] == 'tool_finished'}
        open_tools = {row['correlationID'] for row in pending_trace if row['event'] == 'tool_started'} - completed
        assert len(open_tools) == 1, 'Only the deliberately blocked editor tool should remain open'
        acp.send({'jsonrpc': '2.0', 'method': 'session/cancel', 'params': {'sessionId': sid}})
        assert acp.result(blocked, timeout=10)['stopReason'] == 'cancelled'
        MCP.release.set()
        assert prompt('AFTER_TOOL_CANCEL')['stopReason'] == 'end_turn'
        receipt['checks'].append('pending editor tool evidence, cancellation and next-turn recovery')
        receipt['model_requests'] = len(requests)
        print(json.dumps(receipt, indent=2))
        if os.environ.get('PROXYPILOT_ACP_RECEIPT'): Path(os.environ['PROXYPILOT_ACP_RECEIPT']).write_text(json.dumps(receipt, indent=2)+'\n')
    finally:
        MCP.release.set()
        acp.close()
        model.shutdown()
        mcp.shutdown()
