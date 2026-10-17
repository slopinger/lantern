#!/usr/bin/env python3
"""Isolated regression tests for Lantern. Never connects to live applications."""
import concurrent.futures
import http.client
import http.server
import os
import pathlib
import signal
import socket
import ssl
import subprocess
import tempfile
import threading
import time
import unittest

BINARY = os.environ.get('LANTERN_BIN', str(pathlib.Path('.build/lantern').absolute()))


def free_port():
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0))
        return s.getsockname()[1]


class Running:
    def __init__(self, directory, config, port, startup_timeout=4):
        self.file = directory/'Lanternfile'
        self.file.write_text(config)
        self.logfile = directory/'server.log'
        self.log = self.logfile.open('w+')
        self.proc = subprocess.Popen([BINARY, 'run', str(self.file)], stdout=self.log, stderr=self.log)
        self.port = port
        ready_deadline = time.monotonic()+startup_timeout
        while time.monotonic() < ready_deadline:
            if self.proc.poll() is not None:
                self.log.flush()
                raise AssertionError(self.logfile.read_text())
            try:
                with socket.create_connection(('127.0.0.1', port), timeout=.1):
                    return
            except OSError:
                time.sleep(.02)
        self.log.flush()
        detail = self.logfile.read_text()
        self.close()
        raise AssertionError(f'startup timeout after {startup_timeout}s: {detail}')

    def close(self):
        if self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=12)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait()
                raise AssertionError('graceful shutdown timed out')
        self.log.close()

    def request(self, path='/', method='GET', body=None, host='localhost', headers=None):
        c = http.client.HTTPConnection('127.0.0.1', self.port, timeout=4)
        c.request(method, path, body, {'Host': host, **(headers or {})})
        r = c.getresponse()
        result = r.status, dict(r.getheaders()), r.read()
        c.close()
        return result

    def raw(self, data, fragment=None):
        with socket.create_connection(('127.0.0.1', self.port), timeout=4) as s:
            if fragment:
                for i in range(0, len(data), fragment):
                    s.sendall(data[i:i+fragment])
            else:
                s.sendall(data)
            c = http.client.HTTPResponse(s)
            c.begin()
            return c.status, dict(c.getheaders()), c.read()


class Backend(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    seen = None
    def log_message(self, *_):
        pass
    def do_HEAD(self):
        if self.path.startswith("/http10-transfer-"):
            return self.do_GET()
        self.send_response(200)
        self.send_header('Content-Length', '123')
        self.end_headers()
    def do_GET(self):
        type(self).seen = list(self.headers.items())
        if self.path.startswith('/http10-transfer-'):
            status = self.path.rsplit('-', 1)[1].encode()
            self.wfile.write(b'HTTP/1.0 ' + status + b' Test\r\nTransfer-Encoding: chunked\r\n\r\n'
                             b'0\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n')
            self.wfile.flush()
            self.close_connection = True
        elif self.path == '/bad-framing':
            self.wfile.write(b'HTTP/1.1 200 OK\r\nContent-Length: 5\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n')
            self.wfile.flush()
            self.close_connection = True
        elif self.path == '/chunked':
            self.wfile.write(b'HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: x-private\r\nx-private: secret\r\nSet-Cookie: a=1\r\nSet-Cookie: b=2\r\n\r\n3\r\nabc\r\n2\r\nde\r\n0\r\nx-checksum: discarded\r\n\r\n')
            self.wfile.flush()
        elif self.path == '/close-delimited':
            self.wfile.write(b'HTTP/1.0 200 OK\r\n\r\nclose-body')
            self.wfile.flush()
            self.close_connection = True
        elif self.path == '/drain-hold' and hasattr(self.server, 'drain_entered'):
            self.server.drain_entered.set()
            if not self.server.drain_release.wait(8):
                self.close_connection = True
                return
            self.send_response(200)
            self.send_header('Content-Length', '7')
            self.end_headers()
            self.wfile.write(b'drained')
        elif self.path == '/slow':
            time.sleep(3)
            self.close_connection = True
        elif self.path == '/large':
            self.send_response(200)
            self.send_header('Content-Length', str(2*1024*1024))
            self.end_headers()
            self.wfile.write(b'x'*(2*1024*1024))
        else:
            self.send_response(200)
            self.send_header('Content-Length', str(len(self.path)))
            self.end_headers()
            self.wfile.write(self.path.encode())
    def do_POST(self):
        type(self).seen = list(self.headers.items())
        body = self.rfile.read(int(self.headers['Content-Length']))
        self.send_response(200)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)


class Tests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='lantern-http-test-')
        self.d = pathlib.Path(self.tmp.name)
        self.root = self.d/'public'
        self.root.mkdir()
        (self.root/'index.html').write_text('hello static')
        (self.root/'binary.bin').write_bytes(bytes(range(256))*1000)
        (self.root/'nested').mkdir()
        (self.root/'nested'/'index.html').write_text('nested index')
        (self.root/'.secret').write_text('hidden secret')
        outside = self.d/'outside.txt'
        outside.write_text('outside secret')
        (self.root/'escape').symlink_to(outside)
        (self.root/'escape-dir').symlink_to(self.d, target_is_directory=True)
        os.mkfifo(self.root/'pipe')
        self.backend = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Backend)
        self.bt = threading.Thread(target=self.backend.serve_forever, daemon=True)
        self.bt.start()
        self.port = free_port()
        self.config = f'''listen 127.0.0.1:{self.port}
header_timeout 1
body_timeout 1
write_timeout 1
body_limit 1024
max_connections 32
site localhost {{ root ./public }}
site proxy.local {{ reverse_proxy http://localhost:{self.backend.server_port} }}
site text.local {{ respond "hello text" header Content-Type "text/x-test" }}
site redirect.local {{ redirect https://example.com/fixed }}
'''
        self.server = Running(self.d, self.config, self.port)

    def tearDown(self):
        self.server.close()
        self.backend.shutdown()
        self.backend.server_close()
        self.tmp.cleanup()

    def test_mixed_path_routes(self):
        self.server.close()
        config = self.config + f'''site mixed.local {{
  root ./public
  header X-Site mixed
  handle /api/* {{ reverse_proxy http://localhost:{self.backend.server_port} }}
  handle /api/health {{ respond healthy }}
  handle_path /stripped/* {{ reverse_proxy http://localhost:{self.backend.server_port} }}
  handle_path /mounted/* {{ root ./public }}
  handle /old {{ redirect https://example.com/new }}
}}
site routes.local {{ handle /health {{ respond up }} handle /nested/* {{ root ./public }} }}
'''
        self.server = Running(self.d, config, self.port)
        self.assertEqual(self.server.request(host='mixed.local')[2], b'hello static')
        status, headers, body = self.server.request('/api/users?q=1', host='mixed.local')
        self.assertEqual((status, body, headers['x-site']), (200, b'/api/users?q=1', 'mixed'))
        self.assertEqual(self.server.request('/api/health?detail=1', host='mixed.local')[2], b'healthy')
        self.assertEqual(self.server.request('/stripped/users?q=1', host='mixed.local')[2], b'/users?q=1')
        self.assertEqual(self.server.request('/mounted/', host='mixed.local')[2], b'hello static')
        self.assertEqual(self.server.request('/mounted/nested?q=1', host='mixed.local')[1]['location'], '/mounted/nested/?q=1')
        self.assertEqual(self.server.request('/old', host='mixed.local')[1]['location'], 'https://example.com/new')
        self.assertEqual(self.server.request('/api', host='mixed.local')[0], 404)
        self.assertEqual(self.server.request('/health', host='routes.local')[2], b'up')
        self.assertEqual(self.server.request('/nested/', host='routes.local')[2], b'nested index')
        self.assertEqual(self.server.request('/missing', host='routes.local')[0], 404)

    def test_static_and_head(self):
        status, headers, body = self.server.request()
        self.assertEqual((status, body), (200, b'hello static'))
        self.assertEqual(headers['x-content-type-options'], 'nosniff')
        self.assertEqual(self.server.request('/binary.bin')[2], bytes(range(256))*1000)
        self.assertEqual(self.server.request('/nested/')[2], b'nested index')
        status, headers, body = self.server.request(method='HEAD')
        self.assertEqual((status, body, headers['content-length']), (200, b'', '12'))
        self.assertEqual(self.server.request('/missing', method='HEAD')[::2], (404, b''))
        status, headers, body = self.server.request(method='POST', body=b'x')
        self.assertEqual(status, 405)
        self.assertEqual(headers['allow'], 'GET, HEAD')

    def test_file_confinement(self):
        for target in ['/../outside.txt', '/%2e%2e/outside.txt', '/nested/%2e%2e/%2e%2e/outside.txt',
                       '/.secret', '/%2esecret', '/escape', '/escape-dir/outside.txt', '/pipe',
                       '/%00', '/%5c../outside.txt', '//outside.txt', '/%ff', '/bad%z0']:
            with self.subTest(target=target):
                status, _, body = self.server.request(target)
                self.assertIn(status, (400, 404))
                self.assertNotIn(b'secret', body)

    def test_hosts_and_fixed_response(self):
        self.assertEqual(self.server.request(host='unconfigured.example')[0], 421)
        self.assertEqual(self.server.request(host='localhost:8080')[0], 200)
        self.assertEqual(self.server.request(host='LOCALHOST')[0], 200)
        self.assertEqual(self.server.request(host='localhost.evil')[0], 421)
        status, headers, body = self.server.request(host='text.local')
        self.assertEqual((status, body, headers['content-type']), (200, b'hello text', 'text/x-test'))
        self.assertEqual(self.server.request(host='redirect.local')[1]['location'], 'https://example.com/fixed')

    def test_bad_requests(self):
        for extra in [b'Content-Length: 0\r\nTransfer-Encoding: chunked\r\n',
                      b'Content-Length: 0\r\nContent-Length: 0\r\n',
                      b'Content-Length: -1\r\n', b'Connection: host\r\n',
                      b'Host: duplicate\r\n', b'Bad : space\r\n', b' continuation\r\n']:
            with self.subTest(extra=extra):
                self.assertEqual(self.server.raw(b'POST / HTTP/1.1\r\nHost: localhost\r\n'+extra+b'\r\n')[0], 400)
        self.assertEqual(self.server.raw(b'POST / HTTP/1.1\r\nHost: proxy.local\r\nContent-Length: 1025\r\n\r\n')[0], 413)
        self.assertEqual(self.server.raw(b'GET / HTTP/1.1\r\nHost: localhost\r\nX: '+b'a'*8193+b'\r\n\r\n')[0], 431)
        self.assertEqual(self.server.request(method='TRACE')[0], 501)
        self.assertEqual(self.server.request(headers={'Upgrade':'websocket'})[0], 501)

    def test_expect_and_deadlines(self):
        self.assertEqual(self.server.request(headers={'Expect':'other'})[0], 417)
        with socket.create_connection(('127.0.0.1', self.port), timeout=4) as s:
            s.sendall(b'POST / HTTP/1.1\r\nHost: proxy.local\r\nExpect: 100-continue\r\nContent-Length: 3\r\n\r\n')
            self.assertEqual(s.recv(1024), b'HTTP/1.1 100 Continue\r\n\r\n')
            s.sendall(b'abc')
            r = http.client.HTTPResponse(s)
            r.begin()
            self.assertEqual((r.status, r.read()), (200, b'abc'))
        for wire in [b'GET / HTTP/1.1\r\nHost:', b'POST / HTTP/1.1\r\nHost: proxy.local\r\nContent-Length: 3\r\n\r\na']:
            self.assertEqual(self.server.raw(wire)[0], 408)

    def test_proxy_rejects_http10_transfer_encoding(self):
        for method, status in [('GET', 200), ('HEAD', 200), ('GET', 304), ('GET', 103)]:
            with self.subTest(method=method, status=status):
                actual, _, _ = self.server.request(f'/http10-transfer-{status}',
                                                    host='proxy.local', method=method)
                self.assertEqual(actual, 502)

    def test_proxy_headers_and_streaming(self):
        status, _, body = self.server.request('/path?x=1', host='proxy.local', headers={
            'Forwarded':'for=evil', 'X-Forwarded-For':'evil', 'X-Forwarded-Host':'evil',
            'X-Forwarded-Proto':'https', 'X-Real-IP':'evil', 'Connection':'x-private','X-Private':'secret'})
        self.assertEqual((status, body), (200, b'/path?x=1'))
        seen = {k.lower():v for k,v in Backend.seen}
        self.assertEqual(seen['x-forwarded-for'], '127.0.0.1')
        self.assertEqual(seen['x-forwarded-proto'], 'http')
        self.assertEqual(seen['x-forwarded-host'], 'proxy.local')
        self.assertNotIn('forwarded', seen)
        self.assertNotIn('x-private', seen)
        status, headers, body = self.server.request('/chunked', host='proxy.local')
        self.assertEqual((status, body), (200, b'abcde'))
        self.assertNotIn('x-private', headers)
        self.assertNotIn('x-checksum', headers)
        self.assertEqual(self.server.request('/close-delimited', host='proxy.local')[2], b'close-body')
        self.assertEqual(self.server.request('/large', host='proxy.local')[2], b'x'*(2*1024*1024))
        self.assertEqual(self.server.request('/bad-framing', host='proxy.local')[0], 502)
        self.assertIn(self.server.request('/slow', host='proxy.local')[0], (408, 504))
        self.assertEqual(self.server.request(host='proxy.local', method='HEAD')[2], b'')

    def test_chunked_and_pipelining(self):
        wire = b'POST / HTTP/1.1\r\nHost: proxy.local\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n2\r\nde\r\n0\r\nX-Checksum: x\r\n\r\n'
        self.assertEqual(self.server.raw(wire, fragment=1)[2], b'abcde')
        with socket.create_connection(('127.0.0.1', self.port), timeout=4) as s:
            s.sendall(b'GET / HTTP/1.1\r\nHost: text.local\r\n\r\nGET / HTTP/1.1\r\nHost: text.local\r\nConnection: close\r\n\r\n')
            data = b''
            while True:
                b = s.recv(65536)
                if not b:break
                data += b
            self.assertEqual(data.count(b'HTTP/1.1 200 OK'), 2)
            self.assertEqual(data.count(b'hello text'), 2)
        result = self.server.raw(b'GET /chunked HTTP/1.0\r\nHost: proxy.local\r\n\r\n')
        self.assertEqual(result[2], b'abcde')
        self.assertNotIn('transfer-encoding', result[1])

    def test_clean_peer_eof_between_requests(self):
        with socket.create_connection(('127.0.0.1', self.port), timeout=4) as peer:
            peer.sendall(b'GET / HTTP/1.1\r\nHost: text.local\r\n\r\n')
            response = http.client.HTTPResponse(peer); response.begin()
            self.assertEqual((response.status, response.read()), (200, b'hello text'))
            response.close()
            peer.shutdown(socket.SHUT_WR)
            self.assertEqual(peer.recv(1), b'', 'clean request-boundary EOF generated a response')

    def test_shutdown_closes_idle_keepalive_without_waiting_for_grace(self):
        self.server.close()
        config = self.config.replace('header_timeout 1', 'header_timeout 30')
        self.server = Running(self.d, config, self.port)
        with socket.create_connection(('127.0.0.1', self.port), timeout=4) as peer:
            peer.sendall(b'GET / HTTP/1.1\r\nHost: text.local\r\n\r\n')
            response = http.client.HTTPResponse(peer); response.begin()
            self.assertEqual((response.status, response.read()), (200, b'hello text'))
            response.close()
            self.server.proc.send_signal(signal.SIGTERM)
            self.assertEqual(self.server.proc.wait(timeout=2), 0)
            self.assertEqual(peer.recv(1), b'')

    def test_shutdown_idle_tls_sends_close_notify(self):
        self.server.close()
        cert, key = self.d/'cert.pem', self.d/'key.pem'
        subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
                        '-days', '1', '-subj', '/CN=localhost', '-addext',
                        'subjectAltName=DNS:localhost', '-keyout', str(key), '-out', str(cert)],
                       check=True, capture_output=True)
        cfg = (f'listen 127.0.0.1:{self.port}\nheader_timeout 30\n'
               'tls cert.pem key.pem\nsite localhost { respond "TLS works" }\n')
        self.server = Running(self.d, cfg, self.port)
        ctx = ssl.create_default_context(cafile=str(cert))
        with socket.create_connection(('127.0.0.1', self.port), timeout=4) as raw:
            with ctx.wrap_socket(raw, server_hostname='localhost', suppress_ragged_eofs=False) as peer:
                peer.sendall(b'GET / HTTP/1.1\r\nHost: localhost\r\n\r\n')
                response = http.client.HTTPResponse(peer); response.begin()
                self.assertEqual((response.status, response.read()), (200, b'TLS works'))
                response.close()
                self.server.proc.send_signal(signal.SIGTERM)
                self.assertEqual(peer.recv(1), b'')  # SSLEOFError on missing close_notify.
                self.assertEqual(self.server.proc.wait(timeout=2), 0)

    def test_shutdown_finishes_active_request_without_admitting_keepalive_work(self):
        self.server.close()
        config = self.config.replace('header_timeout 1', 'header_timeout 30').replace('write_timeout 1', 'write_timeout 30')
        self.server = Running(self.d, config, self.port)
        self.backend.drain_entered = threading.Event()
        self.backend.drain_release = threading.Event()
        try:
            with socket.create_connection(('127.0.0.1', self.port), timeout=4) as active, \
                 socket.create_connection(('127.0.0.1', self.port), timeout=4) as idle, \
                 socket.create_connection(('127.0.0.1', self.port), timeout=4) as expecting:
                idle.sendall(b'GET / HTTP/1.1\r\nHost: text.local\r\n\r\n')
                response = http.client.HTTPResponse(idle); response.begin()
                self.assertEqual((response.status, response.read()), (200, b'hello text'))
                response.close()
                expecting.sendall(b'GET / HTTP/1.1\r\nHost: text.local\r\n\r\n')
                response = http.client.HTTPResponse(expecting); response.begin()
                self.assertEqual((response.status, response.read()), (200, b'hello text'))
                response.close()
                active.sendall(b'GET /drain-hold HTTP/1.1\r\nHost: proxy.local\r\n\r\n'
                               b'GET / HTTP/1.1\r\nHost: text.local\r\nConnection: close\r\n\r\n')
                self.assertTrue(self.backend.drain_entered.wait(3), 'active request did not reach upstream')
                self.server.proc.send_signal(signal.SIGTERM)
                deadline = time.monotonic()+3
                while True:
                    try:
                        with socket.create_connection(('127.0.0.1', self.port), timeout=.1):
                            pass
                    except OSError:
                        break
                    self.assertLess(time.monotonic(), deadline, 'listener stayed open after SIGTERM')
                    time.sleep(.01)
                # The closed listener proves stop committed; an existing socket
                # must not admit new application work after that boundary.
                for peer, request in [
                    (idle, b'GET / HTTP/1.1\r\nHost: text.local\r\nConnection: close\r\n\r\n'),
                    (expecting, b'POST / HTTP/1.1\r\nHost: proxy.local\r\nContent-Length: 5\r\n'
                                b'Expect: 100-continue\r\n\r\n')]:
                    try:
                        peer.sendall(request)
                        with peer.makefile('rb') as reply:
                            first_line = reply.readline(1024)
                        self.assertTrue(not first_line or first_line.startswith(b'HTTP/1.1 503 '), first_line)
                    except (BrokenPipeError, ConnectionResetError):
                        pass  # Idle sockets are closed immediately on stop.
                self.backend.drain_release.set()
                finished = http.client.HTTPResponse(active); finished.begin()
                self.assertEqual((finished.status, finished.read()), (200, b'drained'))
                self.assertEqual(finished.getheader('Connection'), 'close')
                finished.close()
                self.assertEqual(active.recv(1), b'', 'buffered pipeline request dispatched while draining')
            self.assertEqual(self.server.proc.wait(timeout=3), 0)
        finally:
            self.backend.drain_release.set()

    def test_reload_preserves_old_on_error(self):
        self.server.file.write_text(self.config.replace('hello text','new text'))
        self.server.proc.send_signal(signal.SIGHUP)
        for _ in range(100):
            if self.server.request(host='text.local')[2] == b'new text':break
            time.sleep(.02)
        else:self.fail('reload never applied')
        self.server.file.write_text('invalid configuration')
        self.server.proc.send_signal(signal.SIGHUP)
        time.sleep(.1)
        self.assertEqual(self.server.request(host='text.local')[2], b'new text')
        self.assertIsNone(self.server.proc.poll())

    def test_concurrency_and_limit(self):
        with concurrent.futures.ThreadPoolExecutor(max_workers=12) as pool:
            results = list(pool.map(lambda _: self.server.request(host='text.local'), range(100)))
        self.assertTrue(all(r[0]==200 for r in results))
        sockets=[]
        try:
            for _ in range(32):
                sockets.append(socket.create_connection(('127.0.0.1', self.port), timeout=2))
            time.sleep(.1)
            with socket.create_connection(('127.0.0.1', self.port), timeout=2) as rejected:
                rejected.settimeout(.5)
                self.assertEqual(rejected.recv(1), b'')
        finally:
            for s in sockets:s.close()

    def test_atomic_file_replacement_and_symlink_race(self):
        target=self.root/'race'
        target.write_text('safe')
        done=threading.Event()
        def mutate():
            while not done.is_set():
                candidate=self.root/'replacement'
                candidate.write_text('safe')
                os.replace(candidate,target)
                candidate.symlink_to(self.d/'outside.txt')
                os.replace(candidate,target)
        worker=threading.Thread(target=mutate,daemon=True);worker.start()
        try:
            for _ in range(100):
                status,_,body=self.server.request('/race')
                self.assertIn(status,(200,404))
                if status==200:self.assertEqual(body,b'safe')
                self.assertNotIn(b'outside secret',body)
        finally:
            done.set();worker.join(timeout=2)

    def test_body_admission_budget(self):
        self.server.close()
        cfg=self.config.replace('body_limit 1024','body_limit 16777216').replace('body_timeout 1','body_timeout 5')
        self.server=Running(self.d,cfg,self.port)
        held=[]
        try:
            for _ in range(4):
                s=socket.create_connection(('127.0.0.1',self.port),timeout=3)
                s.sendall(b'POST / HTTP/1.1\r\nHost: proxy.local\r\nContent-Length: 16777216\r\nExpect: 100-continue\r\n\r\n')
                self.assertEqual(s.recv(1024),b'HTTP/1.1 100 Continue\r\n\r\n')
                held.append(s)
            self.assertEqual(self.server.raw(b'POST / HTTP/1.1\r\nHost: proxy.local\r\nContent-Length: 16777216\r\n\r\n')[0],503)
            self.assertEqual(self.server.request(host='text.local')[0],200)
        finally:
            for s in held:s.close()

    def test_tls(self):
        self.server.close()
        cert,key=self.d/'cert.pem',self.d/'key.pem'
        subprocess.run(['openssl','req','-x509','-newkey','rsa:2048','-nodes','-days','1','-subj','/CN=localhost',
                        '-addext','subjectAltName=DNS:localhost','-keyout',str(key),'-out',str(cert)],check=True,capture_output=True)
        cfg=f'listen 127.0.0.1:{self.port}\ntls cert.pem key.pem\nsite localhost {{ respond "TLS works" }}\n'
        self.server=Running(self.d,cfg,self.port)
        ctx=ssl.create_default_context(cafile=str(cert));ctx.set_ecdh_curve('X25519')
        c=http.client.HTTPSConnection('localhost',self.port,context=ctx,timeout=4)
        c.request('GET','/')
        r=c.getresponse()
        self.assertEqual((r.status,r.read()),(200,b'TLS works'))
        c.close()
        p256=ssl.create_default_context(cafile=str(cert));p256.set_ecdh_curve('prime256v1')
        c=http.client.HTTPSConnection('localhost',self.port,context=p256,timeout=4)
        c.request('GET','/')
        r=c.getresponse();self.assertEqual((r.status,r.read()),(200,b'TLS works'));c.close()
        # An idle peer's authenticated write closure must receive only a TLS
        # close reply, rather than a fabricated HTTP 400 after the last response.
        with socket.create_connection(('127.0.0.1', self.port), timeout=4) as raw:
            with ctx.wrap_socket(raw, server_hostname='localhost') as peer:
                peer.sendall(b'GET / HTTP/1.1\r\nHost: localhost\r\n\r\n')
                response = http.client.HTTPResponse(peer); response.begin()
                self.assertEqual((response.status, response.read()), (200, b'TLS works'))
                response.close()
                peer.unwrap().close()
        original=cert.read_bytes()
        cert.write_text('invalid PEM')
        self.server.proc.send_signal(signal.SIGHUP)
        time.sleep(.1)
        self.assertIsNone(self.server.proc.poll(),'invalid TLS reload killed the server')
        c=http.client.HTTPSConnection('localhost',self.port,context=ctx,timeout=4)
        c.request('GET','/')
        r=c.getresponse();self.assertEqual((r.status,r.read()),(200,b'TLS works'));c.close()
        cert.write_bytes(original)


if __name__=='__main__':
    unittest.main(verbosity=2)
