#!/usr/bin/env python3
"""Linux syscall observations for a verified, loopback-only static workload."""
import argparse
import hashlib
import http.client
import json
import os
import pathlib
import platform
import signal
import socket
import subprocess
import tempfile
import time


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--lantern', default='./result/bin/lantern')
    parser.add_argument('--strace', default='strace')
    parser.add_argument('--out', required=True)
    args = parser.parse_args()
    binary = pathlib.Path(args.lantern).resolve()
    with tempfile.TemporaryDirectory(prefix='lantern-syscalls-') as temporary:
        directory = pathlib.Path(temporary)
        (directory/'payload.bin').write_bytes(b'x'*4096)
        with socket.socket() as available:
            available.bind(('127.0.0.1', 0))
            port = available.getsockname()[1]
        config = directory/'Lanternfile'
        config.write_text(f'listen 127.0.0.1:{port}\nsite localhost {{ root {directory} }}\n')
        with (directory/'server.log').open('w') as log:
            process = subprocess.Popen([args.strace, '--kill-on-exit', '-f', '-c', '-o', str(directory/'syscalls.txt'),
                str(binary), 'run', str(config), '+RTS', '-s'], stdout=log, stderr=log)
            try:
                for _ in range(200):
                    if process.poll() is not None:
                        raise RuntimeError('server exited during startup')
                    try:
                        with socket.create_connection(('127.0.0.1', port), timeout=.1):
                            break
                    except OSError:
                        time.sleep(.02)
                else:
                    raise RuntimeError('server startup timeout')
                for _ in range(10):
                    connection = http.client.HTTPConnection('127.0.0.1', port, timeout=5)
                    try:
                        for _ in range(100):
                            connection.request('GET', '/payload.bin', headers={'Host': 'localhost'})
                            response = connection.getresponse()
                            assert response.status == 200 and response.read() == b'x'*4096
                    finally:
                        connection.close()
            finally:
                if process.poll() is None:
                    # strace owns one child; terminate that disposable server,
                    # letting the tracer finish its summary and the RTS flush stats.
                    children = pathlib.Path(f'/proc/{process.pid}/task/{process.pid}/children').read_text().split()
                    for child in children:
                        try:
                            os.kill(int(child), signal.SIGTERM)
                        except ProcessLookupError:
                            pass
                    try:
                        process.wait(timeout=15)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()
                        raise
        report = {'date_utc': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
                  'kernel': platform.release(), 'binary_sha256': hashlib.sha256(binary.read_bytes()).hexdigest(),
                  'requests': 1000, 'body_bytes': 4096, 'connections': 10, 'requests_per_connection': 100,
                  'notes': ['All response bytes verified; temporary loopback instance only.',
                            'Tracing perturbs timing; compare syscall counts, not traced throughput.',
                            'Counts include startup, shutdown and the readiness connection.'],
                  'strace_summary': (directory/'syscalls.txt').read_text(),
                  'server_log_and_rts_stats': (directory/'server.log').read_text()}
        pathlib.Path(args.out).write_text(json.dumps(report, indent=2)+'\n')
    print('Verified 1000 responses; wrote '+args.out)


if __name__ == '__main__':
    main()
