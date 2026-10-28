#!/usr/bin/env python3
import http.server, json, pathlib, sys, time
mode, port_file, hit_file = sys.argv[1:]
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def send(self, code, value):
        data = json.dumps(value).encode()
        self.send_response(code); self.send_header('Content-Type','application/json'); self.send_header('Content-Length',str(len(data))); self.end_headers()
        try: self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError): pass
    def do_GET(self):
        if self.path == '/unexpected':
            pathlib.Path(hit_file).write_text('redirect followed')
            return self.send(200, {'data':[{'id':'unsafe'}]})
        if mode == 'redirect':
            self.send_response(302); self.send_header('Location','/unexpected'); self.send_header('Content-Length','0'); self.end_headers(); return
        if mode == 'empty': return self.send(200, {'data':[]})
        self.send(200, {'data':[{'id':'fixture-model'}]})
    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        assert request['model'] == 'fixture-model' and request['stream'] is False
        text = request['messages'][-1]['content']
        if text == 'SLOW': time.sleep(.5)
        if text == 'FAIL': return self.send(503, {'error':'fixture failure'})
        self.send(200, {'choices':[{'message':{'role':'assistant','content':'로컬 기록 정리'}}]})
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
pathlib.Path(port_file).write_text(str(server.server_port))
server.serve_forever()
