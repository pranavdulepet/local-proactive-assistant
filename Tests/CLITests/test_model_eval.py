#!/usr/bin/env python3
"""Exercise model-eval through a loopback fixture, without personal sources or sends."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import subprocess
import sys
import threading
import unittest

CLI = Path(sys.argv.pop(1)).resolve() if len(sys.argv) > 1 else Path('.build/debug/assistantctl').resolve()


class ModelEvaluationTests(unittest.TestCase):
    def setUp(self):
        self.calls = []
        captured = self.calls

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def respond(self, body):
                data = json.dumps(body).encode()
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Content-Length', str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def do_GET(self):
                captured.append((self.path, None))
                self.respond({'models': [{'name': 'synthetic:latest'}]})

            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                captured.append((self.path, body))
                if body.get('format') == 'json':
                    content = json.dumps({'insufficientEvidence': False, 'claims': [
                        {'text': 'The demo project deadline is Friday at 5 PM.', 'evidenceIDs': ['demo1']}
                    ]})
                    message = {'role': 'assistant', 'content': content}
                elif body['messages'][-1]['role'] == 'tool':
                    message = {'role': 'assistant', 'content': 'The demo project deadline is Friday at 5 PM. [e1]'}
                else:
                    message = {'role': 'assistant', 'content': '', 'tool_calls': [
                        {'function': {'name': 'searchIndex', 'arguments': {'query': 'demo project deadline'}}}
                    ]}
                self.respond({'done': True, 'message': message})

        self.server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)

    def evaluate(self, *args):
        return subprocess.run([str(CLI), 'model-eval', '--model', 'ollama',
                               '--model-url', f'http://127.0.0.1:{self.server.server_port}',
                               '--model-name', 'synthetic', *args], text=True, capture_output=True, timeout=15)

    def test_selected_ollama_provider_evaluates_synthetic_evidence(self):
        result = self.evaluate()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('Evaluating ollama:synthetic', result.stdout)
        self.assertIn('Friday at 5 PM', result.stdout)
        self.assertEqual([path for path, _ in self.calls], ['/api/tags', '/api/chat'])
        payload = self.calls[1][1]
        self.assertEqual(payload['model'], 'synthetic')
        self.assertIn('Synthetic public fixture', payload['messages'][-1]['content'])

    def test_conversation_evaluation_executes_production_read_loop(self):
        result = self.evaluate('--conversation')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('Synthetic conversation read and citation checks passed', result.stdout)
        self.assertIn('read searchIndex:', result.stdout)
        self.assertEqual([path for path, _ in self.calls], ['/api/tags', '/api/chat', '/api/chat'])
        payload = self.calls[-1][1]
        self.assertEqual(payload['messages'][-1]['role'], 'tool')
        self.assertEqual(payload['messages'][-1]['tool_name'], 'searchIndex')
        self.assertIn('Friday at 5 PM', payload['messages'][-1]['content'])

    def test_unknown_options_fail_before_model_or_source_access(self):
        result = self.evaluate('--typo')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Unexpected model-eval arguments', result.stderr)
        self.assertEqual(self.calls, [])


if __name__ == '__main__':
    unittest.main()
