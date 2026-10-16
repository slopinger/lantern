#!/usr/bin/env python3
"""Isolated real HTTP tests for conditional static files and range framing."""
import datetime
import email.parser
import email.policy
import email.utils
import http.client
import os
import pathlib
import ssl
import subprocess
import tempfile
import threading
import unittest
from http_test import Running, free_port


class Tests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='lantern-static-')
        self.directory = pathlib.Path(self.tmp.name)
        self.root = self.directory/'public'
        self.root.mkdir()
        self.data = bytes(range(256))*1024
        (self.root/'binary.bin').write_bytes(self.data)
        (self.root/'empty').write_bytes(b'')
        (self.root/'index.html').write_text('hello conditional')
        port = free_port()
        self.server = Running(self.directory, f'''listen 127.0.0.1:{port}
site localhost {{ root public header Cache-Control "public, max-age=60" }}
site typed.local {{ root public header Content-Type "application/x-test" }}
site encoded.local {{ root public header Content-Encoding gzip }}
''', port)

    def tearDown(self):
        self.server.close()
        self.tmp.cleanup()

    def test_conditional_precedence_and_dates(self):
        status, headers, body = self.server.request()
        self.assertEqual((status, body), (200, b'hello conditional'))
        tag, modified = headers['etag'], headers['last-modified']
        self.assertTrue(tag.startswith('W/"'))
        for condition in [{'If-None-Match': tag}, {'If-None-Match': tag[2:]},
                          {'If-None-Match': '"a,b", '+tag}, {'If-None-Match': '*'},
                          {'If-Modified-Since': modified}]:
            with self.subTest(condition=condition):
                result, metadata, content = self.server.request(headers=condition)
                self.assertEqual((result, content), (304, b''))
                self.assertNotIn('content-length', metadata)
                self.assertEqual(metadata['etag'], tag)
                self.assertEqual(metadata['cache-control'], 'public, max-age=60')
        date = email.utils.parsedate_to_datetime(modified)
        for format in ['%A, %d-%b-%y %H:%M:%S GMT', '%a %b %e %H:%M:%S %Y']:
            self.assertEqual(self.server.request(headers={'If-Modified-Since': date.strftime(format)})[0], 304)
        self.assertEqual(self.server.request(headers={'If-Match': tag})[0], 412)
        self.assertEqual(self.server.request(headers={'If-Match': tag[2:]})[0], 412)
        self.assertEqual(self.server.request(headers={'If-Match': '*'})[0], 200)
        self.assertEqual(self.server.request(headers={'If-None-Match': ''})[0], 200)
        self.assertEqual(self.server.request(headers={'If-Match': ''})[0], 412)
        past = email.utils.format_datetime(date-datetime.timedelta(days=1), usegmt=True)
        self.assertEqual(self.server.request(headers={'If-Unmodified-Since': past})[0], 412)
        self.assertEqual(self.server.request(headers={'If-Match': '*', 'If-Unmodified-Since': past})[0], 200)
        self.assertEqual(self.server.request(headers={'If-None-Match': '"different"', 'If-Modified-Since': modified})[0], 200)
        self.assertEqual(self.server.request(headers={'If-Match': '"different"', 'If-None-Match': '*'})[0], 412)
        self.assertEqual(self.server.request(headers={'If-None-Match': '*', 'Range': 'bytes=999999-'})[0], 304)
        self.assertEqual(self.server.request('/missing', headers={'If-Match': '"different"'})[0], 404)
        for malformed in ['"unterminated', '*, "other"', 'w/"tag"']:
            self.assertEqual(self.server.request(headers={'If-None-Match': malformed})[0], 400)
        self.assertEqual(self.server.request(headers={'If-Modified-Since': 'invalid'})[0], 200)
        self.assertEqual(self.server.request(method='HEAD', headers={'If-None-Match': tag})[::2], (304, b''))
        self.assertEqual(self.server.request(method='HEAD', headers={'If-Match': '"different"'})[::2], (412, b''))

    def test_single_ranges_and_if_range(self):
        length = len(self.data)
        for field, start, end in [('bytes=0-0', 0, 1), ('bytes=3-9', 3, 10),
                                  ('bytes=262140-', length-4, length),
                                  ('bytes=-7', length-7, length),
                                  ('bytes=20-'+('9'*4096), 20, length),
                                  ('bytes=-'+('9'*4096), 0, length)]:
            with self.subTest(field=field[:50]):
                status, headers, body = self.server.request('/binary.bin', headers={'Range': field})
                self.assertEqual((status, body), (206, self.data[start:end]))
                self.assertEqual(headers['content-range'], f'bytes {start}-{end-1}/{length}')
                self.assertEqual(int(headers['content-length']), end-start)
        for field in ['bytes=-0', 'bytes=999999-', 'bytes='+('9'*4096)+'-',
                      'bytes='+','.join(['0-1']*17)]:
            status, headers, body = self.server.request('/binary.bin', headers={'Range': field})
            self.assertEqual(status, 416)
            self.assertEqual(headers['content-range'], f'bytes */{length}')
            self.assertNotEqual(body, self.data)
        for field in ['unknown=0-1', 'bytes=4-2', 'bytes=bad', 'bytes=1 -3']:
            self.assertEqual(self.server.request('/binary.bin', headers={'Range': field})[::2], (200, self.data))
        status, headers, body = self.server.request('/binary.bin', method='HEAD', headers={'Range': 'bytes=999999-'})
        self.assertEqual((status, body, int(headers['content-length'])), (200, b'', length))
        full = self.server.request('/binary.bin')[1]
        for validator in [full['etag'], full['etag'][2:], full['last-modified'], 'invalid']:
            self.assertEqual(self.server.request('/binary.bin', headers={'Range': 'bytes=0-1', 'If-Range': validator})[::2], (200, self.data))
        self.assertEqual(self.server.request('/empty', headers={'Range': 'bytes=0-'})[0], 416)
        self.assertEqual(self.server.request('/empty', headers={'Range': 'bytes=-1'})[::2], (200, b''))
        status, metadata, _ = self.server.request('/binary.bin', host='encoded.local', headers={'Range': 'bytes=0-1'})
        self.assertEqual(status, 200)
        self.assertEqual(metadata['accept-ranges'], 'none')
        status, metadata, _ = self.server.request('/binary.bin', host='encoded.local', headers={'If-Match': '"invalid"'})
        self.assertEqual(status, 412)
        self.assertNotIn('content-encoding', metadata)

    def test_multipart_framing_and_coalescing(self):
        status, headers, body = self.server.request('/binary.bin', host='typed.local', headers={'Range': 'bytes=8-11,0-1,20-22'})
        self.assertEqual(status, 206)
        self.assertEqual(int(headers['content-length']), len(body))
        self.assertNotIn('content-range', headers)
        parsed = email.parser.BytesParser(policy=email.policy.default).parsebytes(
            b'Content-Type: '+headers['content-type'].encode()+b'\r\nMIME-Version: 1.0\r\n\r\n'+body)
        self.assertTrue(parsed.is_multipart())
        parts = list(parsed.iter_parts())
        self.assertEqual(len(parts), 3)
        for part, (start, end) in zip(parts, [(8, 12), (0, 2), (20, 23)]):
            self.assertEqual(part['content-type'], 'application/x-test')
            self.assertEqual(part['content-range'], f'bytes {start}-{end-1}/{len(self.data)}')
            self.assertEqual(part.get_payload(decode=True), self.data[start:end])
        status, headers, body = self.server.request('/binary.bin', headers={'Range': 'bytes=0-4,2-7,8-10,999999-'})
        self.assertEqual((status, body), (206, self.data[:11]))
        self.assertEqual(headers['content-range'], f'bytes 0-10/{len(self.data)}')
        # Two requests on one connection catch extra/missing multipart bytes.
        connection = http.client.HTTPConnection('127.0.0.1', self.server.port, timeout=4)
        try:
            connection.request('GET', '/binary.bin', headers={'Host': 'localhost', 'Range': 'bytes=0-1,8-9'})
            response = connection.getresponse(); self.assertEqual(response.status, 206); response.read()
            connection.request('GET', '/', headers={'Host': 'localhost'})
            response = connection.getresponse(); self.assertEqual(response.read(), b'hello conditional')
            tag = response.getheader('etag')
            connection.request('GET', '/', headers={'Host': 'localhost', 'If-None-Match': tag})
            response = connection.getresponse(); self.assertEqual((response.status, response.read()), (304, b''))
            connection.request('GET', '/', headers={'Host': 'localhost'})
            self.assertEqual(connection.getresponse().read(), b'hello conditional')
        finally:
            connection.close()

    def test_verified_tls_ranges_and_conditional_reuse(self):
        self.server.close()
        cert, key = self.directory/'cert.pem', self.directory/'key.pem'
        subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
                        '-subj', '/CN=localhost', '-addext', 'subjectAltName=DNS:localhost',
                        '-keyout', str(key), '-out', str(cert)], check=True, capture_output=True)
        port = free_port()
        self.server = Running(self.directory, f'listen 127.0.0.1:{port}\ntls cert.pem key.pem\nsite localhost {{ root public }}\n', port)
        context = ssl.create_default_context(cafile=str(cert))
        context.set_ecdh_curve('prime256v1')
        connection = http.client.HTTPSConnection('localhost', port, context=context, timeout=4)
        try:
            connection.request('GET', '/binary.bin', headers={'Range': 'bytes=0-131071'})
            response = connection.getresponse()
            self.assertEqual((response.status, response.read()), (206, self.data[:131072]))
            tag = response.getheader('etag')
            connection.request('GET', '/binary.bin', headers={'If-None-Match': tag, 'Range': 'bytes=0-1'})
            response = connection.getresponse()
            self.assertEqual((response.status, response.read()), (304, b''))
            connection.request('HEAD', '/binary.bin', headers={'Range': 'bytes=0-1'})
            response = connection.getresponse()
            self.assertEqual((response.status, response.read(), int(response.getheader('content-length'))),
                             (200, b'', len(self.data)))
        finally:
            connection.close()

    def test_atomic_publication_and_confined_ranges(self):
        original = self.server.request()[1]['etag']
        replacement = self.root/'replacement'
        replacement.write_text('newer conditional')
        original_stat = (self.root/'index.html').stat()
        os.utime(replacement, ns=(original_stat.st_atime_ns, original_stat.st_mtime_ns))
        os.replace(replacement, self.root/'index.html')
        status, headers, body = self.server.request(headers={'If-None-Match': original})
        self.assertEqual((status, body), (200, b'newer conditional'))
        self.assertNotEqual(headers['etag'], original)
        outside = self.directory/'outside'
        outside.write_text('private bytes')
        (self.root/'escape').symlink_to(outside)
        for path in ['/escape', '/%2e%2e/outside']:
            self.assertIn(self.server.request(path, headers={'Range': 'bytes=0-1'})[0], [400, 404])
        target = self.root/'rotating'
        target.write_bytes(b'A'*100)
        stopped = threading.Event()
        def rotate():
            while not stopped.is_set():
                candidate = self.root/'next'
                candidate.write_bytes(b'B'*200); os.replace(candidate, target)
                candidate.write_bytes(b'A'*100); os.replace(candidate, target)
        worker = threading.Thread(target=rotate, daemon=True); worker.start()
        try:
            for _ in range(100):
                status, headers, body = self.server.request('/rotating', headers={'Range': 'bytes=-5'})
                self.assertEqual(status, 206)
                if headers['content-range'].endswith('/100'):
                    self.assertEqual(body, b'A'*5)
                else:
                    self.assertEqual(headers['content-range'], 'bytes 195-199/200')
                    self.assertEqual(body, b'B'*5)
        finally:
            stopped.set(); worker.join(timeout=2)


if __name__ == '__main__':
    unittest.main(verbosity=2)
