#!/usr/bin/env python3
"""Reproducible local HTTP/1 benchmark; matched bodies, no external traffic."""
import argparse
import hashlib
import http.client
import json
import os
import pathlib
import platform
import re
import shutil
import socket
import statistics
import subprocess
import tempfile
import time


def port():
    with socket.socket() as s:
        s.bind(('127.0.0.1',0))
        return s.getsockname()[1]


def rss(pid):
    try:
        line=next(l for l in pathlib.Path(f'/proc/{pid}/status').read_text().splitlines() if l.startswith('VmRSS:'))
        return int(line.split()[1])*1024
    except (OSError,StopIteration):return None


def main():
    p=argparse.ArgumentParser()
    p.add_argument('--lantern',default='./result/bin/lantern')
    p.add_argument('--caddy',default=shutil.which('caddy'))
    p.add_argument('--wrk',default=shutil.which('wrk'))
    p.add_argument('--duration',type=int,default=4)
    p.add_argument('--trials',type=int,default=3)
    p.add_argument('--out',default='benchmark.json')
    args=p.parse_args()
    assert args.caddy and args.wrk,'caddy and wrk are required'
    binary=str(pathlib.Path(args.lantern).resolve())
    results={'date_utc':time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime()),'kernel':platform.release(),
             'architecture':platform.machine(),'logical_cpus':os.cpu_count(),'server_runtime_threads':2,
             'generator_threads':2,'connections':32,'seconds_per_trial':args.duration,'trials':args.trials,
             'lantern_sha256':hashlib.sha256(pathlib.Path(binary).read_bytes()).hexdigest(),
             'caddy_version':subprocess.check_output([args.caddy,'version'],text=True).strip(),
             'notes':['shared VM; warm page cache; loopback HTTP/1.1 only; no TLS or WAN claim',
                      'both server runtimes set to two schedulers; no CPU affinity isolation',
                      'default serving policies differ; Lantern closes connections after 100 requests',
                      'client verifies matching file bytes before measurements; responses are not compressed'],
             'results':[]}
    with tempfile.TemporaryDirectory(prefix='lantern-benchmark-') as tmp:
        d=pathlib.Path(tmp)
        for size in [4096,1048576]:(d/f'payload-{size}.bin').write_bytes(b'x'*size)
        for server in ['lantern','caddy']:
            listen=port()
            config=d/(server+'file')
            if server=='lantern':
                config.write_text(f'listen 127.0.0.1:{listen}\nsite localhost {{ root {d} }}\n')
                command=[binary,'run',str(config)]
            else:
                config.write_text(f'{{\n admin off\n auto_https off\n persist_config off\n}}\nhttp://localhost:{listen} {{\n bind 127.0.0.1\n root * {d}\n file_server\n}}\n')
                command=[args.caddy,'run','--config',str(config),'--adapter','caddyfile']
            with (d/f'{server}.log').open('w') as log:
                process=subprocess.Popen(command,stdout=log,stderr=log,env={**os.environ,'GOMAXPROCS':'2'})
                try:
                    for _ in range(200):
                        if process.poll() is not None:raise RuntimeError((d/f'{server}.log').read_text())
                        try:
                            with socket.create_connection(('127.0.0.1',listen),timeout=.1):break
                        except OSError:time.sleep(.02)
                    for size in [4096,1048576]:
                        path=f'/payload-{size}.bin'
                        c=http.client.HTTPConnection('127.0.0.1',listen,timeout=3)
                        c.request('GET',path,headers={'Host':'localhost'})
                        r=c.getresponse();assert r.status==200 and r.read()==b'x'*size;c.close()
                        base=[args.wrk,'-t2','-c32','-H','Host: localhost','--latency',f'http://127.0.0.1:{listen}{path}']
                        subprocess.run(base+['-d1s'],check=True,capture_output=True)
                        trials=[]
                        for trial in range(args.trials):
                            out=subprocess.check_output(base+[f'-d{args.duration}s'],text=True)
                            if 'Socket errors:' in out or 'Non-2xx or 3xx responses:' in out:raise AssertionError(out)
                            rate=float(re.search(r'Requests/sec:\s+([\d.]+)',out)[1])
                            trials.append({'requests_per_second':rate,'rss_bytes_after_trial':rss(process.pid),'wrk_output':out})
                        median=statistics.median(t['requests_per_second'] for t in trials)
                        results['results'].append({'server':server,'body_bytes':size,'median_requests_per_second':median,
                            'median_body_mib_per_second':median*size/(1024*1024),'trials':trials})
                        print(f'{server}: {size} bytes, median {median:.1f} requests/s, {median*size/(1024*1024):.1f} body MiB/s',flush=True)
                finally:
                    process.terminate()
                    try:process.wait(timeout=15)
                    except subprocess.TimeoutExpired:process.kill();process.wait()
    pathlib.Path(args.out).write_text(json.dumps(results,indent=2)+'\n')
    print('wrote '+args.out,flush=True)


if __name__=='__main__':main()
