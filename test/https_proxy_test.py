#!/usr/bin/env python3
"""Loopback HTTPS proxy checks using independent Python/OpenSSL TLS peers."""
import datetime
import http.server
import pathlib
import signal
import socket
import ssl
import tempfile
import threading
import time
import unittest
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, rsa
from cryptography.x509.oid import NameOID, ExtendedKeyUsageOID, ObjectIdentifier
from http_test import Running, Backend, free_port


def certificate(key, issuer_key, issuer, hostname, ca=False, expired=False, extensions=(), client_only=False):
    now = datetime.datetime.now(datetime.timezone.utc)
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, hostname)])
    builder = (x509.CertificateBuilder().subject_name(name)
            .issuer_name(issuer.subject if issuer else name).public_key(key.public_key())
            .serial_number(x509.random_serial_number())
            .not_valid_before(now-datetime.timedelta(days=2))
            .not_valid_after(now+datetime.timedelta(days=-1 if expired else 1))
            .add_extension(x509.BasicConstraints(ca=ca, path_length=None), critical=True)
            .add_extension(x509.SubjectAlternativeName([x509.DNSName(hostname)]), critical=False)
            .add_extension(x509.KeyUsage(digital_signature=True, content_commitment=False,
                           key_encipherment=False, data_encipherment=False, key_agreement=False,
                           key_cert_sign=ca, crl_sign=ca, encipher_only=None, decipher_only=None), critical=True)
            .add_extension(x509.ExtendedKeyUsage([ExtendedKeyUsageOID.CLIENT_AUTH if client_only else ExtendedKeyUsageOID.SERVER_AUTH]), critical=False)
            )
    for extension, critical in extensions:
        builder = builder.add_extension(extension, critical)
    return builder.sign(issuer_key or key, hashes.SHA256())


class Tests(unittest.TestCase):
    def test_verified_https_upstreams(self):
        with tempfile.TemporaryDirectory(prefix='lantern-https-proxy-') as tmp:
            directory = pathlib.Path(tmp)
            root_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
            root = certificate(root_key, None, None, 'test root', ca=True)
            root_path = directory/'root.pem'
            root_path.write_bytes(root.public_bytes(serialization.Encoding.PEM))
            for kind in ['rsa', 'ecdsa', 'p256', 'wrong-host', 'unknown-ca', 'expired', 'tls12', 'name-constraint', 'critical-extension', 'issuer-purpose', 'weak-issuer', 'weak-leaf']:
                with self.subTest(kind=kind):
                    key = (ec.generate_private_key(ec.SECP256R1()) if kind == 'ecdsa' else
                           rsa.generate_private_key(public_exponent=65537, key_size=2047 if kind == 'weak-leaf' else 2048))
                    issuer_key, issuer = root_key, root
                    chain = b''
                    if kind in ['name-constraint', 'critical-extension', 'issuer-purpose', 'weak-issuer']:
                        issuer_key = rsa.generate_private_key(public_exponent=65537, key_size=1024 if kind == 'weak-issuer' else 2048)
                        extensions = []
                        if kind == 'name-constraint':
                            extensions = [(x509.NameConstraints([x509.DNSName('allowed.test')], None), True)]
                        elif kind == 'critical-extension':
                            extensions = [(x509.UnrecognizedExtension(ObjectIdentifier('1.3.6.1.4.1.55555.7'), b'\x05\x00'), True)]
                        issuer = certificate(issuer_key, root_key, root, 'intermediate', ca=True,
                                             extensions=extensions,
                                             client_only=kind == 'issuer-purpose')
                        chain = issuer.public_bytes(serialization.Encoding.PEM)
                    leaf = certificate(key, key if kind == 'unknown-ca' else issuer_key,
                                       None if kind == 'unknown-ca' else issuer,
                                       'wrong.example' if kind == 'wrong-host' else 'localhost',
                                       expired=kind == 'expired')
                    cert_path, key_path = directory/'leaf.pem', directory/'key.pem'
                    cert_path.write_bytes(leaf.public_bytes(serialization.Encoding.PEM) + chain)
                    key_path.write_bytes(key.private_bytes(serialization.Encoding.PEM,
                        serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
                    backend = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Backend)
                    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
                    context.set_ciphers('DEFAULT:@SECLEVEL=0')  # intentionally weak server fixtures
                    context.load_cert_chain(cert_path, key_path)
                    context.set_ecdh_curve('prime256v1' if kind == 'p256' else 'X25519')
                    context.set_alpn_protocols(['http/1.1'])
                    if kind == 'tls12':
                        context.maximum_version = ssl.TLSVersion.TLSv1_2
                    backend.socket = context.wrap_socket(backend.socket, server_side=True)
                    thread = threading.Thread(target=backend.serve_forever, daemon=True)
                    thread.start()
                    port = free_port()
                    config = (f'listen 127.0.0.1:{port}\nproxy_ca_bundle root.pem\n'
                              f'write_timeout 4\nsite localhost {{ handle /* {{ reverse_proxy https://localhost:{backend.server_port} }} }}\n')
                    server = None
                    Backend.seen = None
                    try:
                        server = Running(directory, config, port)
                        if kind not in ['rsa', 'ecdsa', 'p256']:
                            self.assertEqual(server.request('/private')[0], 502)
                            self.assertIsNone(Backend.seen, 'HTTP sent before authenticated TLS')
                            self.assertIsNone(server.proc.poll())
                            continue
                        self.assertEqual(server.request('/path?x=1')[::2], (200, b'/path?x=1'))
                        self.assertEqual(dict((k.lower(), v) for k, v in Backend.seen)['host'],
                                         f'localhost:{backend.server_port}')
                        self.assertEqual(server.request('/chunked')[2], b'abcde')
                        self.assertEqual(server.request('/large')[2], b'x'*(2*1024*1024))
                        self.assertEqual(server.request(method='POST', body=b'authenticated echo')[2],
                                         b'authenticated echo')
                        self.assertEqual(server.request(method='HEAD')[2], b'')
                        self.assertEqual(server.request('/bad-framing')[0], 502)
                        # Failed trust rotation must retain the entire working snapshot.
                        original = root_path.read_bytes()
                        root_path.write_text('invalid trust bundle')
                        server.proc.send_signal(signal.SIGHUP)
                        for _ in range(100):
                            if 'reload rejected:' in server.logfile.read_text():
                                break
                            time.sleep(.02)
                        else:
                            self.fail('invalid trust reload was not rejected')
                        self.assertEqual(server.request('/still-working')[::2], (200, b'/still-working'))
                        root_path.write_bytes(original)
                        if kind == 'rsa':
                            # Removing trust from a valid replacement bundle takes effect on reload.
                            other_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
                            other_root = certificate(other_key, None, None, 'unrelated root', ca=True)
                            for bundle, expected in [(other_root.public_bytes(serialization.Encoding.PEM), 502),
                                                     (original, 200)]:
                                root_path.write_bytes(bundle)
                                before = server.logfile.read_text().count('configuration reloaded')
                                server.proc.send_signal(signal.SIGHUP)
                                for _ in range(100):
                                    if server.logfile.read_text().count('configuration reloaded') > before:
                                        break
                                    time.sleep(.02)
                                else:
                                    self.fail('valid trust reload was not applied')
                                self.assertEqual(server.request('/rotated')[0], expected)
                            # No configured bundle means system trust, never implicit leaf trust.
                            server.close()
                            server = Running(directory, config.replace('proxy_ca_bundle root.pem\n', ''), port)
                            Backend.seen = None
                            self.assertEqual(server.request('/private')[0], 502)
                            self.assertIsNone(Backend.seen)
                    finally:
                        if server:
                            server.close()
                        backend.shutdown()
                        backend.server_close()
                        thread.join(timeout=2)

    def test_handshake_deadline(self):
        with tempfile.TemporaryDirectory(prefix='lantern-https-deadline-') as tmp:
            directory = pathlib.Path(tmp)
            with socket.socket() as stalled:
                stalled.bind(('127.0.0.1', 0))
                stalled.listen(8)
                port = free_port()
                config = (f'listen 127.0.0.1:{port}\nwrite_timeout 1\n'
                          f'site localhost {{ reverse_proxy https://127.0.0.1:{stalled.getsockname()[1]} }}\n')
                server = Running(directory, config, port)
                try:
                    started = time.monotonic()
                    self.assertEqual(server.request()[0], 504)
                    self.assertLess(time.monotonic()-started, 3)
                    self.assertIsNone(server.proc.poll())
                finally:
                    server.close()


if __name__ == '__main__':
    unittest.main(verbosity=2)
