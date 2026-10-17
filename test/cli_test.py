#!/usr/bin/env python3
"""User-facing CLI checks, including read-only validation and exit behavior."""
import http.client
import signal
import time
import os
import pathlib
import socket
import subprocess
import tempfile
import unittest

BINARY = str(pathlib.Path(os.environ.get('LANTERN_BIN', './result/bin/lantern')).resolve())


class Tests(unittest.TestCase):
    def invoke(self, *arguments, directory=None):
        return subprocess.run([BINARY, *arguments], cwd=directory, capture_output=True,
                              text=True, timeout=5)

    def test_help_and_version_without_configuration(self):
        with tempfile.TemporaryDirectory(prefix='lantern-cli-') as directory:
            for arguments in [[], ['--help'], ['-h'], ['help'], ['help', 'run'],
                              ['run', '--help'], ['check', '-h'], ['serve', '--help'], ['help', 'proxy']]:
                result = self.invoke(*arguments, directory=directory)
                self.assertEqual((result.returncode, result.stderr), (0, ''), result)
                self.assertIn('Usage:', result.stdout)
            for arguments in [['version'], ['--version']]:
                result = self.invoke(*arguments, directory=directory)
                self.assertEqual((result.returncode, result.stdout, result.stderr),
                                 (0, 'lantern 0.1.0\n', ''))
            self.assertEqual(list(pathlib.Path(directory).iterdir()), [])

    def test_help_example_is_a_working_configuration(self):
        with tempfile.TemporaryDirectory(prefix='lantern-cli-') as temporary:
            help_result = self.invoke('--help', directory=temporary)
            example = next(line.strip() for line in help_result.stdout.splitlines()
                           if line.strip().startswith('site localhost'))
            (pathlib.Path(temporary)/'Lanternfile').write_text(example+'\n')
            checked = self.invoke('check', directory=temporary)
            self.assertEqual((checked.returncode, checked.stdout, checked.stderr),
                             (0, 'configuration valid\n', ''))

    def test_c_locale_diagnostics_stay_utf8(self):
        with tempfile.TemporaryDirectory(prefix='lantern-cli-') as directory:
            environment = {**os.environ, 'LC_ALL': 'C', 'LANG': 'C'}
            result = subprocess.run([BINARY, '--help'], cwd=directory, env=environment,
                                    capture_output=True, timeout=5)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('Lantern — experimental'.encode(), result.stdout)
            missing = str(pathlib.Path(directory)/'missing-ä.conf')
            result = subprocess.run([BINARY, 'check', missing], env=environment,
                                    capture_output=True, timeout=5)
            self.assertEqual(result.returncode, 1)
            self.assertIn('missing-ä.conf'.encode(), result.stderr)
            self.assertNotIn(b'HasCallStack', result.stderr)

    def test_argument_errors_keep_exit_status_and_one_diagnostic(self):
        for arguments in [['nonsense'], ['run', '--config'], ['check', '--bogus'], ['check', '--config='],
                          ['help', 'nonsense'], ['version', '--bogus']]:
            with self.subTest(arguments=arguments):
                result = self.invoke(*arguments)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(result.stdout, '')
                self.assertTrue(result.stderr.startswith('lantern: '), result.stderr)
                self.assertIn("lantern --help", result.stderr)
                if arguments[0] == 'version':
                    self.assertIn('does not accept arguments', result.stderr)
                for internals in ['ExitFailure', 'HasCallStack', 'collectBacktraces']:
                    self.assertNotIn(internals, result.stderr)

    def test_check_paths_errors_and_utf8(self):
        with tempfile.TemporaryDirectory(prefix='lantern-cli-') as temporary:
            directory = pathlib.Path(temporary)
            file = directory/'-site ä.conf'
            file.write_text('site localhost { respond "ok" }\n')
            for arguments in [['check', '--', file.name], ['check', '--config', file.name], ['check', '--config='+file.name]]:
                result = self.invoke(*arguments, directory=directory)
                self.assertEqual((result.returncode, result.stdout, result.stderr),
                                 (0, 'configuration valid\n', ''))
            file.write_text('site localhost {\n  unknown value\n}\n')
            result = self.invoke('check', '--config', str(file))
            self.assertEqual(result.returncode, 1)
            self.assertIn('line 2', result.stderr)
            self.assertIn('unknown site directive', result.stderr)
            self.assertNotIn('HasCallStack', result.stderr)
            file.write_bytes(b'\xff')
            result = self.invoke('check', '--', str(file))
            self.assertEqual(result.returncode, 1)
            self.assertIn('valid UTF-8', result.stderr)
            result = self.invoke('check', str(directory/'missing.conf'))
            self.assertEqual(result.returncode, 1)
            self.assertIn('missing.conf', result.stderr)
            self.assertNotIn('HasCallStack', result.stderr)

    def test_run_options_serve_and_stop_cleanly(self):
        with tempfile.TemporaryDirectory(prefix='lantern-cli-') as temporary:
            directory = pathlib.Path(temporary)
            (directory/'index.html').write_text('hello CLI')
            for command, options in [('run', ['--config', '-site.conf']), ('run', ['--', '-site.conf']), ('serve', ['.'])]:
                with socket.socket() as available:
                    available.bind(('127.0.0.1', 0))
                    port = available.getsockname()[1]
                (directory/'-site.conf').write_text(f'listen 127.0.0.1:{port}\nsite localhost {{ respond "hello CLI" }}\n')
                arguments = [BINARY, command, *options] + (['--listen', f'127.0.0.1:{port}'] if command == 'serve' else [])
                process = subprocess.Popen(arguments, cwd=directory,
                                           stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                try:
                    for _ in range(150):
                        try:
                            with socket.create_connection(('127.0.0.1', port), timeout=.1):
                                break
                        except OSError:
                            time.sleep(.02)
                    else:
                        self.fail('CLI-selected server did not start')
                    connection = http.client.HTTPConnection('127.0.0.1', port, timeout=3)
                    try:
                        connection.request('GET', '/', headers={'Host': 'arbitrary.example' if command == 'serve' else 'localhost'})
                        response = connection.getresponse()
                        self.assertEqual((response.status, response.read()), (200, b'hello CLI'))
                    finally:
                        connection.close()
                    process.send_signal(signal.SIGTERM)
                    _, error = process.communicate(timeout=12)
                    self.assertEqual(process.returncode, 0, error)
                finally:
                    if process.poll() is None:
                        process.kill()
                    process.communicate(timeout=3)

    def test_interrupt_during_configuration_read(self):
        with tempfile.TemporaryDirectory(prefix='lantern-cli-') as temporary:
            file = pathlib.Path(temporary)/'pending.conf'
            os.mkfifo(file)
            writer = os.open(file, os.O_RDWR | os.O_NONBLOCK)
            process = subprocess.Popen([BINARY, 'check', str(file)],
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                for _ in range(150):
                    opened = []
                    for descriptor in pathlib.Path(f'/proc/{process.pid}/fd').iterdir():
                        try:
                            opened.append(os.readlink(descriptor))
                        except FileNotFoundError:
                            pass
                    if str(file) in opened:
                        break
                    time.sleep(.02)
                else:
                    self.fail('configuration read did not begin')
                process.send_signal(signal.SIGINT)
                output, error = process.communicate(timeout=3)
                self.assertEqual((process.returncode, output, error), (130, b'', b''))
            finally:
                os.close(writer)
                if process.poll() is None:
                    process.kill()
                process.communicate(timeout=3)

    def test_invalid_automatic_settings_fail_before_side_effects(self):
        with tempfile.TemporaryDirectory(prefix='lantern-cli-') as temporary:
            directory = pathlib.Path(temporary)
            with socket.socket() as occupied, socket.socket() as ca:
                occupied.bind(('127.0.0.1', 0)); occupied.listen()
                ca.bind(('127.0.0.1', 0)); ca.listen(); ca.settimeout(.1)
                config = directory/'Lanternfile'
                prefix = ('listen 127.0.0.1:8443\n'
                          'auto_https test@example.com ./private-state\n'
                          f'acme_http_port {occupied.getsockname()[1]}\n')
                cases = [('https://[localhost]:443/directory', 'example.test', 'endpoint'),
                         (f'https://127.0.0.1:{ca.getsockname()[1]}/directory', '192.0.2.1', 'DNS names')]
                for endpoint, name, diagnostic in cases:
                    config.write_text(prefix + f'acme_ca {endpoint}\nsite {name} {{ respond ok }}\n')
                    for command in ['check', 'run']:
                        result = self.invoke(command, directory=directory)
                        self.assertEqual(result.returncode, 1, result)
                        self.assertIn(diagnostic, result.stderr)
                        self.assertNotIn('Address already in use', result.stderr)
                        self.assertEqual(list(directory.iterdir()), [config])
                with self.assertRaises(TimeoutError):
                    ca.accept()

    def test_automatic_check_does_not_bind_contact_or_create_state(self):
        with tempfile.TemporaryDirectory(prefix='lantern-cli-') as temporary:
            directory = pathlib.Path(temporary)
            with socket.socket() as occupied, socket.socket() as ca:
                occupied.bind(('127.0.0.1', 0)); occupied.listen()
                ca.bind(('127.0.0.1', 0)); ca.listen(); ca.settimeout(.1)
                file = directory/'Lanternfile'
                file.write_text(f'listen 127.0.0.1:{occupied.getsockname()[1]}\n'
                    'auto_https test@example.com ./private-state\n'
                    f'acme_ca https://127.0.0.1:{ca.getsockname()[1]}/directory\n'
                    'site example.test { respond "ok" }\n')
                result = self.invoke('check', directory=directory)
                self.assertEqual((result.returncode, result.stdout, result.stderr),
                                 (0, 'configuration valid\n', ''))
                with self.assertRaises(TimeoutError):
                    ca.accept()
                self.assertEqual(list(directory.iterdir()), [file])


if __name__ == '__main__':
    unittest.main(verbosity=2)
