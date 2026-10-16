#!/usr/bin/env python3
"""UTF-8 filesystem confinement must not depend on the server's process locale."""
import http.client
import os
import pathlib
import subprocess
import tempfile
import time
import unittest
from http_test import BINARY, free_port


class Tests(unittest.TestCase):
    def test_c_locale_keeps_validated_paths_exact(self):
        for root_name in ['public', 'public-ä']:
            with self.subTest(root=root_name):
                with tempfile.TemporaryDirectory(prefix='lantern-path-encoding-') as tmp:
                    directory = pathlib.Path(tmp)
                    root = directory/root_name
                    root.mkdir()
                    (root/'unicode-ä').mkdir()
                    (root/'unicode-ä'/'index.html').write_text('UTF-8 directory index')
                    (root/'ä.txt').write_text('visible UTF-8 file')
                    (root/'.secret').write_text('synthetic hidden fixture')
                    (root/'public.txt').write_text('distinct ASCII file')
                    port = free_port()
                    config = directory/('Lanternfile-ä' if root_name != 'public' else 'Lanternfile')
                    config.write_text(f'listen 127.0.0.1:{port}\nsite localhost {{ root {root_name} }}\n')
                    with (directory/'server.log').open('w+') as log:
                        process = subprocess.Popen([BINARY, 'run', str(config)], stdout=log, stderr=log,
                                                   env={**os.environ, 'LC_ALL': 'C', 'LANG': 'C'})
                        def request(path):
                            connection = http.client.HTTPConnection('127.0.0.1', port, timeout=4)
                            try:
                                connection.request('GET', path, headers={'Host': 'localhost'})
                                response = connection.getresponse()
                                return response.status, response.read()
                            finally:
                                connection.close()
                        try:
                            for _ in range(200):
                                if process.poll() is not None:
                                    log.seek(0); self.fail(log.read())
                                try:
                                    if request('/public.txt')[0] == 200:
                                        break
                                except OSError:
                                    time.sleep(.02)
                            else:
                                self.fail('C-locale server did not start')
                            self.assertEqual(request('/%C3%A4.txt'), (200, b'visible UTF-8 file'))
                            self.assertEqual(request('/unicode-%C3%A4/index.html'), (200, b'UTF-8 directory index'))
                            for target in ['/%C3%A4.secret', '/.%C3%A4secret', '/%C3%A4public.txt',
                                           '/%C3%A4%2e%2e/public.txt', '/%C3%A4%2e/public.txt']:
                                with self.subTest(target=target):
                                    status, body = request(target)
                                    self.assertIn(status, [400, 404])
                                    self.assertNotIn(b'synthetic hidden fixture', body)
                                    self.assertNotIn(b'distinct ASCII file', body)
                            self.assertEqual(request('/.secret')[0], 400)
                        finally:
                            process.terminate()
                            try:
                                process.wait(timeout=12)
                            except subprocess.TimeoutExpired:
                                process.kill(); process.wait()
                                raise AssertionError('C-locale server failed to stop')


if __name__ == '__main__':
    unittest.main(verbosity=2)
