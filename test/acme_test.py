#!/usr/bin/env python3
"""Disposable ACME CA fixture verifies real JWS/CSR and fetches actual HTTP-01.
Crypto/test HTTPS use established Python libraries; Lantern uses its own stack.
"""
import concurrent.futures
import base64
import datetime
import hashlib
import http.client
import http.server
import json
import os
import pathlib
import secrets
import signal
import socket
import ssl
import subprocess
import tempfile
import threading
import time
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding, rsa
from cryptography.x509.oid import NameOID
from http_test import free_port, Running, BINARY


def check_shared_admission(http_port, tls_port, hostname):
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.minimum_version = context.maximum_version = ssl.TLSVersion.TLSv1_3
    context.set_ecdh_curve('X25519')
    context.set_alpn_protocols(['http/1.1'])
    outgoing = ssl.MemoryBIO()
    handshake = context.wrap_bio(ssl.MemoryBIO(), outgoing, server_hostname=hostname)
    try:
        handshake.do_handshake()
    except ssl.SSLWantReadError:
        pass
    hello = outgoing.read()
    barrier = threading.Barrier(2)
    def connect(port):
        barrier.wait(timeout=3)
        return socket.create_connection(('127.0.0.1', port), timeout=3)
    admitted_rounds = 0
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as workers:
        for round_number in range(400):
            futures = [workers.submit(connect, port) for port in [http_port, tls_port]]
            peers = [future.result(timeout=4) for future in futures]
            try:
                messages = [f'GET /limit HTTP/1.1\r\nHost: {hostname}\r\n\r\n'.encode(), hello]
                live = []
                for peer, message in zip(peers, messages):
                    peer.settimeout(.5)
                    try:
                        peer.sendall(message)
                    except (BrokenPipeError, ConnectionResetError):
                        pass
                for index, peer in enumerate(peers):
                    try:
                        first = peer.recv(1)
                    except ConnectionResetError:
                        first = b''
                    assert first in ([b'', b'H'] if index == 0 else [b'', b'\x16']), (index, first)
                    live.append(bool(first))
                # HTTP is now held in keepalive; TLS awaits the client's Finished.
                # Positive protocol bytes prove admission, rather than TCP backlog.
                assert sum(live) <= 1, ('shared admission limit exceeded', round_number, live)
                admitted_rounds += any(live)
            finally:
                for peer in peers:
                    peer.close()
            time.sleep(.005)
    assert admitted_rounds >= 50, ('admission stopped making progress', admitted_rounds)
    print(f'Shared admission passed: 400 simultaneous HTTP/TLS arrivals, {admitted_rounds} rounds with service')


def b64(b):
    return base64.urlsafe_b64encode(b).rstrip(b'=')


def unb64(b):
    if isinstance(b, str):b=b.encode()
    return base64.urlsafe_b64decode(b+b'='*((-len(b))%4))


def cert(key, ca_key, ca_cert, names, ca=False):
    now=datetime.datetime.now(datetime.timezone.utc)
    name=x509.Name([x509.NameAttribute(NameOID.COMMON_NAME,names[0])])
    builder=x509.CertificateBuilder().subject_name(name).issuer_name(ca_cert.subject if ca_cert else name).public_key(key.public_key()).serial_number(x509.random_serial_number()).not_valid_before(now-datetime.timedelta(minutes=5)).not_valid_after(now+datetime.timedelta(days=30))
    builder=builder.add_extension(x509.BasicConstraints(ca=ca,path_length=None),critical=True)
    builder=builder.add_extension(x509.SubjectAlternativeName([x509.DNSName(n) for n in names]),critical=False)
    builder=builder.add_extension(x509.KeyUsage(digital_signature=True,content_commitment=False,key_encipherment=not ca,data_encipherment=False,key_agreement=False,key_cert_sign=ca,crl_sign=ca,encipher_only=None,decipher_only=None),critical=True)
    builder=builder.add_extension(x509.SubjectKeyIdentifier.from_public_key(key.public_key()),critical=False)
    builder=builder.add_extension(x509.AuthorityKeyIdentifier.from_issuer_public_key((ca_key or key).public_key()),critical=False)
    return builder.sign(ca_key or key,hashes.SHA256())


class CA(http.server.BaseHTTPRequestHandler):
    protocol_version='HTTP/1.1'
    state=None
    def log_message(self,*_):pass
    def response(self, code, data=None, raw=None, **headers):
        state=type(self).state
        nonce=b64(os.urandom(24)).decode();state['nonces'].add(nonce)
        payload=raw if raw is not None else json.dumps(data or {},separators=(',',':')).encode()
        self.send_response(code)
        self.send_header('Content-Length',str(len(payload)))
        self.send_header('Replay-Nonce',nonce)
        self.send_header('Content-Type','application/json' if raw is None else 'application/pem-certificate-chain')
        for k,v in headers.items():self.send_header(k,v)
        self.end_headers()
        if self.command!='HEAD':self.wfile.write(payload)
    def do_HEAD(self):self.response(200,raw=b'')
    def do_GET(self):
        s=type(self).state
        assert self.path=='/directory'
        self.response(200,{k:s['base']+'/'+v for k,v in [('newNonce','nonce'),('newAccount','account'),('newOrder','new-order')]})
    def do_POST(self):
        s=type(self).state
        try:
            jws=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
            protected=json.loads(unb64(jws['protected']))
            assert protected['alg']=='RS256'
            assert protected['url']==s['base']+self.path
            nonce=protected['nonce'];assert nonce in s['nonces'];s['nonces'].remove(nonce)
            jwk=protected.get('jwk',s.get('jwk'))
            assert jwk and jwk['kty']=='RSA'
            key=rsa.RSAPublicNumbers(int.from_bytes(unb64(jwk['e']),'big'),int.from_bytes(unb64(jwk['n']),'big')).public_key()
            key.verify(unb64(jws['signature']),(jws['protected']+'.'+jws['payload']).encode(),padding.PKCS1v15(),hashes.SHA256())
            payload=unb64(jws['payload'])
            if not s['bad_nonce_done']:
                s['bad_nonce_done']=True
                self.response(400,{'type':'urn:ietf:params:acme:error:badNonce'})
                return
            if self.path=='/account':
                assert protected.get('jwk')==jwk
                assert json.loads(payload)['termsOfServiceAgreed'] is True
                s['jwk']=jwk
                self.response(201,{'status':'valid'},Location=s['base']+'/account/1')
                return
            assert protected['kid']==s['base']+'/account/1'
            if self.path=='/new-order':
                assert json.loads(payload)['identifiers']==[{'type':'dns','value':s['name']}]
                s['orders']+=1;s['valid']=False;s['issued']=False
                self.response(201,self.order(),Location=s['base']+'/order/1')
            elif self.path=='/auth/1':
                assert payload==b''
                self.response(200,{'identifier':{'type':'dns','value':s['name']},'status':'valid' if s['valid'] else 'pending','challenges':[{'type':'http-01','url':s['base']+'/challenge/1','token':s['token']}]})
            elif self.path=='/challenge/1':
                assert json.loads(payload)=={}
                c=http.client.HTTPConnection('127.0.0.1',s['http_port'],timeout=4)
                c.request('GET','/.well-known/acme-challenge/'+s['token'],headers={'Host':s['name']})
                r=c.getresponse();body=r.read();assert r.status==200;c.close()
                thumb=b64(hashlib.sha256(json.dumps(s['jwk'],sort_keys=True,separators=(',',':')).encode()).digest())
                assert body==s['token'].encode()+b'.'+thumb
                s['valid']=True;s['challenge_fetches']+=1
                self.response(200,{'status':'valid'})
            elif self.path=='/order/1':
                assert payload==b''
                self.response(200,self.order(),**{'Retry-After':'0'})
            elif self.path=='/finalize/1':
                csr=x509.load_der_x509_csr(unb64(json.loads(payload)['csr']))
                assert csr.is_signature_valid
                names=csr.extensions.get_extension_for_class(x509.SubjectAlternativeName).value.get_values_for_type(x509.DNSName)
                assert names==[s['name']]
                if s['fail_next']:
                    s['fail_next']=False
                    self.response(503,{'type':'urn:ietf:params:acme:error:serverInternal'},**{'Retry-After':'600'})
                    return
                leaf=self.sign_csr(csr,names)
                s['chain']=leaf.public_bytes(serialization.Encoding.PEM)+s['ca_cert'].public_bytes(serialization.Encoding.PEM)
                s['issued']=True
                self.response(200,self.order())
            elif self.path=='/certificate/1':
                assert payload==b'' and s['issued']
                self.response(200,raw=s['chain'])
            else:raise AssertionError('unexpected path')
        except Exception as e:
            s['errors'].append(type(e).__name__+': '+str(e))
            self.response(500,{'type':'fixture-error'})
    def order(self):
        s=type(self).state
        return {'status':'valid' if s['issued'] else ('ready' if s['valid'] else 'pending'),
            'authorizations':[s['base']+'/auth/1'],'finalize':s['base']+'/finalize/1',
            **({'certificate':s['base']+'/certificate/1'} if s['issued'] else {})}
    def sign_csr(self,csr,names):
        s=type(self).state;now=datetime.datetime.now(datetime.timezone.utc)
        return x509.CertificateBuilder().subject_name(x509.Name([])).issuer_name(s['ca_cert'].subject).public_key(csr.public_key()).serial_number(x509.random_serial_number()).not_valid_before(now-datetime.timedelta(minutes=5)).not_valid_after(now+datetime.timedelta(days=30)).add_extension(x509.BasicConstraints(ca=False,path_length=None),critical=True).add_extension(x509.SubjectAlternativeName([x509.DNSName(n) for n in names]),critical=True).add_extension(x509.KeyUsage(digital_signature=True,content_commitment=False,key_encipherment=True,data_encipherment=False,key_agreement=False,key_cert_sign=False,crl_sign=False,encipher_only=None,decipher_only=None),critical=True).add_extension(x509.SubjectKeyIdentifier.from_public_key(csr.public_key()),critical=False).add_extension(x509.AuthorityKeyIdentifier.from_issuer_public_key(s['ca_key'].public_key()),critical=False).sign(s['ca_key'],hashes.SHA256())


def wait_for(test, timeout=20):
    until=time.monotonic()+timeout
    while time.monotonic()<until:
        if test():return
        time.sleep(.05)
    raise AssertionError('condition did not become true')


def main():
    with tempfile.TemporaryDirectory(prefix='lantern-acme-test-') as tmp:
        d=pathlib.Path(tmp)
        ca_key=rsa.generate_private_key(65537,2048);ca_cert=cert(ca_key,None,None,['test root'],ca=True)
        api_key=rsa.generate_private_key(65537,2048);api_cert=cert(api_key,ca_key,ca_cert,['localhost'])
        for path,content in [(d/'root.pem',ca_cert.public_bytes(serialization.Encoding.PEM)),(d/'api.pem',api_cert.public_bytes(serialization.Encoding.PEM)),(d/'api-key.pem',api_key.private_bytes(serialization.Encoding.PEM,serialization.PrivateFormat.PKCS8,serialization.NoEncryption()))]:
            path.write_bytes(content);path.chmod(0o600)
        https=http.server.ThreadingHTTPServer(('127.0.0.1',0),CA)
        ctx=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER);ctx.minimum_version=ssl.TLSVersion.TLSv1_3;ctx.set_ecdh_curve('X25519')
        ctx.load_cert_chain(d/'api.pem',d/'api-key.pem')
        https.socket=ctx.wrap_socket(https.socket,server_side=True)
        port,http_port=free_port(),free_port()
        state={'base':f'https://localhost:{https.server_port}','name':'acme-test.example','token':b64(os.urandom(24)).decode(),
               'nonces':set(),'orders':0,'bad_nonce_done':False,'valid':False,'issued':False,'fail_next':False,
               'http_port':http_port,'ca_key':ca_key,'ca_cert':ca_cert,'errors':[],'challenge_fetches':0}
        CA.state=state
        threading.Thread(target=https.serve_forever,daemon=True).start()
        cfg=f'''listen 127.0.0.1:{port}
acme_http_port {http_port}
auto_https test@example.com ./state
acme_ca {state['base']}/directory
acme_ca_bundle ./root.pem
site {state['name']} {{ respond "ACME works" }}
'''
        server=None
        try:
            # Initial provisioning includes probabilistic RSA key generation and
            # the complete ACME exchange before the HTTPS listener is ready.
            server=Running(d,cfg,port,startup_timeout=30)
            assert state['bad_nonce_done'] and state['orders']==1 and state['challenge_fetches']==1
            assert not state['errors'],state['errors']
            pem=d/'state'/'chain.pem'
            original=x509.load_pem_x509_certificate(pem.read_bytes()).serial_number
            key_bytes=(d/'state'/'site-key.pem').read_bytes()
            verify=ssl.create_default_context(cafile=str(d/'root.pem'));verify.set_ecdh_curve('X25519')
            def fetch():
                with socket.create_connection(('127.0.0.1',port),timeout=4) as raw:
                    with verify.wrap_socket(raw,server_hostname=state['name']) as s:
                        s.sendall(f"GET / HTTP/1.1\r\nHost: {state['name']}\r\nConnection: close\r\n\r\n".encode())
                        r=http.client.HTTPResponse(s);r.begin();assert r.status==200 and r.read()==b'ACME works'
                        return x509.load_der_x509_certificate(s.getpeercert(binary_form=True)).serial_number
            assert fetch()==original
            server.close();server=Running(d,cfg,port)
            assert state['orders']==1 and fetch()==original,'cached restart placed another order'
            server.proc.send_signal(signal.SIGUSR1)
            wait_for(lambda:'renewed certificate activated' in server.logfile.read_text())
            renewed=x509.load_pem_x509_certificate(pem.read_bytes()).serial_number
            assert renewed!=original and fetch()==renewed
            assert (d/'state'/'site-key.pem').read_bytes()==key_bytes
            assert state['orders']==2 and state['challenge_fetches']==2
            state['fail_next']=True
            server.proc.send_signal(signal.SIGUSR1)
            wait_for(lambda:'renewal failed' in server.logfile.read_text())
            assert fetch()==renewed and x509.load_pem_x509_certificate(pem.read_bytes()).serial_number==renewed
            assert (d/'state'/'retry-until').exists()
            assert not (d/'state'/'pending-chain.pem').exists()
            orders=state['orders']
            server.proc.send_signal(signal.SIGUSR1);time.sleep(.2)
            assert state['orders']==orders,'persisted Retry-After was ignored'
            for path in (d/'state').iterdir():
                assert path.stat().st_mode&0o077==0,str(path)
            assert not state['errors'],state['errors']
            c=http.client.HTTPConnection('127.0.0.1',http_port,timeout=4)
            c.request('GET','/.well-known/acme-challenge/unknown',headers={'Host':state['name']})
            r=c.getresponse();assert r.status==404;r.read();c.close()
            c=http.client.HTTPConnection('127.0.0.1',http_port,timeout=4)
            c.request('GET','/hello?x=1',headers={'Host':state['name']})
            r=c.getresponse();assert r.status==308 and r.getheader('location')==f'https://{state["name"]}:{port}/hello?x=1';r.read();c.close()
            server.close()
            server=Running(d,cfg.replace('auto_https', 'max_connections 1\nauto_https', 1),port)
            check_shared_admission(http_port, port, state['name'])
            def recovered():
                try:
                    return fetch()==renewed
                except (OSError, ssl.SSLError):
                    return False
            wait_for(recovered, timeout=3)  # the last cancelled handshake must release its slot
        finally:
            if server:server.close()
            https.shutdown();https.server_close()
        print('ACME fixture passed: JWS signatures, nonces/badNonce retry, HTTP-01 fetch, CSR/SAN verification, issuance, cached restart, live renewal, failed-renewal rollback, persisted Retry-After, private state')


if __name__=='__main__':main()
