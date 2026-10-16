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
import time
import unittest
import urllib.parse
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

    def test_directory_canonicalization_and_relative_assets(self):
        for name in ['guide', 'space dir', 'unicode-ä']:
            folder = self.root/name
            folder.mkdir()
            (folder/'index.html').write_text('<link rel="stylesheet" href="style.css">directory index')
            (folder/'style.css').write_text('body { color: green; }')
        for path in ['/guide', '/%67uide', '/space%20dir', '/unicode-%C3%A4', '/guide%2f']:
            for query in ['', '?x=1&next=%2f%2fevil.test', '?']:
                with self.subTest(path=path, query=query):
                    status, headers, _ = self.server.request(path+query)
                    self.assertEqual(status, 308)
                    self.assertEqual(headers['location'], path+'/'+query)
                    absolute = urllib.parse.urljoin('https://localhost'+path+query, headers['location'])
                    self.assertEqual(urllib.parse.urlsplit(absolute).netloc, 'localhost')
                    target = urllib.parse.urlsplit(absolute)
                    response = self.server.request(target.path+('?' + target.query if target.query else ''))
                    self.assertEqual(response[0], 200)
                    asset = urllib.parse.urlsplit(urllib.parse.urljoin(absolute, 'style.css'))
                    self.assertEqual(self.server.request(asset.path)[2], b'body { color: green; }')
        status, headers, body = self.server.request('/guide?x=1', method='HEAD')
        self.assertEqual((status, headers['location'], body), (308, '/guide/?x=1', b''))
        self.assertEqual(self.server.request('/guide', headers={'If-None-Match': '*', 'Range': 'bytes=0-1'})[0], 308)
        self.assertEqual(self.server.request('/guide', method='POST')[0], 405)
        self.assertEqual(self.server.request('/missing')[0], 404)
        search_only = self.root/'search-only'
        search_only.mkdir(); (search_only/'index.html').write_text('searchable directory index')
        search_only.chmod(0o111)
        try:
            for _ in range(20):
                self.assertEqual(self.server.request('/search-only')[0], 308)
            self.assertEqual(self.server.request('/search-only/')[2], b'searchable directory index')
        finally:
            search_only.chmod(0o755)
        (self.root/'no-index').mkdir()
        self.assertEqual(self.server.request('/no-index')[0], 308)
        self.assertEqual(self.server.request('/no-index/')[0], 404)
        (self.root/'bad-index').mkdir()
        (self.root/'bad-index'/'index.html').mkdir()
        self.assertEqual(self.server.request('/bad-index/')[0], 404, 'directory index must not create a redirect loop')
        outside = self.directory/'outside-directory'
        outside.mkdir(); (outside/'index.html').write_text('private directory bytes')
        (self.root/'escape-directory').symlink_to(outside, target_is_directory=True)
        (self.root/'linked-index').mkdir()
        (self.root/'linked-index'/'index.html').symlink_to(outside/'index.html')
        for path in ['/escape-directory', '/escape-directory/', '/linked-index/', '/%2fguide', '//guide']:
            status, headers, body = self.server.request(path)
            self.assertIn(status, [400, 404])
            self.assertNotIn('location', headers)
            self.assertNotIn(b'private directory bytes', body)
        # A redirect under a configured Content-Encoding is itself plain text.
        status, headers, _ = self.server.request('/guide', host='encoded.local')
        self.assertEqual(status, 308)
        self.assertNotIn('content-encoding', headers)
        # Reused connections catch an accidental body on a HEAD redirect.
        connection = http.client.HTTPConnection('127.0.0.1', self.server.port, timeout=4)
        try:
            connection.request('HEAD', '/guide', headers={'Host': 'localhost'})
            response = connection.getresponse()
            self.assertEqual((response.status, response.read()), (308, b''))
            connection.request('GET', '/guide/', headers={'Host': 'localhost'})
            self.assertEqual(connection.getresponse().status, 200)
        finally:
            connection.close()
        # Repeated directory observations must not retain the shim's descriptors.
        before = len(list(pathlib.Path(f'/proc/{self.server.proc.pid}/fd').iterdir()))
        for _ in range(200):
            self.assertEqual(self.server.request('/guide')[0], 308)
        for _ in range(100):
            after = len(list(pathlib.Path(f'/proc/{self.server.proc.pid}/fd').iterdir()))
            if after <= before+2:
                break
            time.sleep(.02)
        self.assertLessEqual(after, before+2, 'directory detection leaked descriptors')

    def test_directory_symlink_replacement_race(self):
        public = self.root/'rotating-directory'
        public.mkdir(); (public/'index.html').write_text('safe directory')
        holding = self.root/'.holding-directory'
        outside = self.directory/'private-directory'
        outside.mkdir(); (outside/'index.html').write_text('private directory bytes')
        stopped = threading.Event()
        errors = []
        def rotate():
            try:
                while not stopped.is_set():
                    public.rename(holding)
                    public.symlink_to(outside, target_is_directory=True)
                    public.unlink()
                    holding.rename(public)
            except Exception as error:
                errors.append(error)
            finally:
                if public.is_symlink(): public.unlink()
                if holding.exists(): holding.rename(public)
        worker = threading.Thread(target=rotate, daemon=True); worker.start()
        try:
            for _ in range(100):
                status, headers, body = self.server.request('/rotating-directory')
                self.assertIn(status, [308, 404])
                if status == 308:
                    self.assertEqual(headers['location'], '/rotating-directory/')
                self.assertNotIn(b'private directory bytes', body)
                status, _, body = self.server.request('/rotating-directory/')
                self.assertIn(status, [200, 404])
                if status == 200: self.assertEqual(body, b'safe directory')
                self.assertNotIn(b'private directory bytes', body)
        finally:
            stopped.set(); worker.join(timeout=2)
        self.assertFalse(worker.is_alive())
        self.assertFalse(errors, errors)

    def test_date_refreshes_on_repeated_cached_responses(self):
        first = self.server.request(method='HEAD')[1]['date']
        for _ in range(100):
            metadata = self.server.request(method='HEAD')[1]
            self.assertLessEqual(email.utils.parsedate_to_datetime(metadata['last-modified']),
                                 email.utils.parsedate_to_datetime(metadata['date']))
            if metadata['date'] != first:
                break
            time.sleep(.03)
        else:
            self.fail('Date header stayed frozen on repeated static responses')

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
        cached = self.root/'cached'
        cached.write_bytes(b'previously public')
        previous = self.server.request('/cached')[1]['etag']
        outside = self.directory/'outside'
        outside.write_text('private bytes')
        (self.root/'escape').symlink_to(outside)
        cached.unlink(); cached.symlink_to(outside)
        self.assertEqual(self.server.request('/cached', headers={'If-None-Match': previous})[0], 404,
                         'cached validators must not bypass a new confined open')
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
