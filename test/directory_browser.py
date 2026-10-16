#!/usr/bin/env python3
"""Optional real-browser QA for a disposable loopback directory site."""
import argparse
import json
import pathlib
import shutil
import subprocess
import tempfile
import http_test

HTML = '''<!doctype html><html lang="en"><meta charset="utf-8">
<title>Lantern · Directory URL check</title>
<link rel="stylesheet" href="style.css"><script src="app.js" defer></script>
<main><div class="label">LANTERN / LOCAL BROWSER CHECK</div>
<h1>Relative links,<br>right where they belong.</h1>
<p class="intro">Opened a directory URL without a trailing slash.<br>
The server redirects before the browser resolves this page's assets.</p>
<section><div class="key">CURRENT URL</div><code id="path">waiting for script</code></section>
<div class="grid"><section><div class="key">RELATIVE STYLESHEET</div><strong id="css">waiting</strong></section>
<section><div class="key">RELATIVE JAVASCRIPT</div><strong id="js">waiting</strong></section>
<section><div class="key">RELATIVE JSON FETCH</div><strong id="fetch">waiting</strong></section></div>
<p class="result" id="result">Checking live asset requests…</p>
<footer>A disposable static site served by Lantern's Nix-built executable.<br>
No production service or Caddy configuration was changed.</footer></main></html>'''
CSS = ''' :root { --asset-proof: loaded; color-scheme: dark; }
*{box-sizing:border-box}body{margin:0;background:#101a18;color:#e1eee6;font:22px/1.55 system-ui,sans-serif}
main{max-width:1120px;margin:65px auto;padding:45px;border:1px solid #416858;border-radius:22px;background:#182822}
.label,.key{font:15px/1.5 ui-monospace,monospace;letter-spacing:.12em;color:#94baa6}h1{font-size:60px;line-height:1.1;letter-spacing:-.045em;margin:26px 0;color:#c9f4d5}
.intro{color:#abc9b7;margin-bottom:30px}section{padding:22px;background:#20372d;border:1px solid #395a48;border-radius:12px;margin:16px 0}
code{font:21px/1.8 ui-monospace,monospace}.grid{display:grid;grid-template-columns:repeat(3,1fr);gap:14px}strong{display:block;font-size:23px;color:#b6efc4;margin-top:10px}
.result{padding:14px 0;color:#c9f4d5;font-weight:600}footer{font-size:17px;color:#90ad9c}
'''
SCRIPT = '''const scriptPath = new URL(document.currentScript.src).pathname;
window.addEventListener('load', async () => {
  try {
    const response = await fetch('asset.json'); const asset = await response.json();
    const css = getComputedStyle(document.documentElement).getPropertyValue('--asset-proof').trim() === 'loaded';
    const path = location.pathname; const query = new URL(location.href).searchParams;
    const expected = ['/guide/', '/guide//'].includes(decodeURIComponent(path)) && path.endsWith('/') && query.get('check') === '1';
    document.querySelector('#path').textContent = path + location.search;
    document.querySelector('#css').textContent = css ? 'loaded ✓' : 'failed';
    document.querySelector('#js').textContent = scriptPath.includes('guide') ? 'loaded ✓' : 'failed';
    document.querySelector('#fetch').textContent = 'HTTP ' + response.status;
    const ok = css && expected && response.status === 200 && asset.proof === 'relative asset';
    document.documentElement.dataset.qa = ok ? 'passed' : 'failed';
    document.querySelector('#result').textContent = ok ? 'Trailing slash added · query preserved · relative assets loaded' : 'Browser check failed';
  } catch (error) { document.documentElement.dataset.qa = 'failed'; document.querySelector('#result').textContent = String(error); }
});'''


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', default='./result/bin/lantern')
    parser.add_argument('--chromium', default=shutil.which('chromium'))
    parser.add_argument('--out', required=True)
    args = parser.parse_args()
    assert args.chromium, 'a Chromium executable is required'
    http_test.BINARY = str(pathlib.Path(args.binary).resolve())
    output = pathlib.Path(args.out).absolute()
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='lantern-directory-browser-') as tmp:
        directory = pathlib.Path(tmp)
        guide = directory/'public'/'guide'
        guide.mkdir(parents=True)
        (guide/'index.html').write_text(HTML)
        (guide/'style.css').write_text(CSS)
        (guide/'app.js').write_text(SCRIPT)
        (guide/'asset.json').write_text(json.dumps({'proof': 'relative asset'}))
        port = http_test.free_port()
        server = http_test.Running(directory, f'listen 127.0.0.1:{port}\nsite localhost {{ root public }}\n', port)
        try:
            observations = []
            for index, path in enumerate(['/guide?check=1', '/guide%2f?check=1']):
                url = f'http://localhost:{port}'+path
                command = [args.chromium, '--headless', '--no-sandbox', '--disable-gpu',
                           '--hide-scrollbars', '--virtual-time-budget=2000',
                           '--user-data-dir='+str(directory/f'profile-{index}'), '--dump-dom', url]
                result = subprocess.run(command, check=True, capture_output=True, text=True, timeout=30)
                assert 'data-qa="passed"' in result.stdout, result.stdout[-3000:]
                observations.append({'requested_target': path, 'relative_assets': 'verified'})
            command = [args.chromium, '--headless', '--no-sandbox', '--disable-gpu',
                       '--hide-scrollbars', '--virtual-time-budget=2000',
                       '--user-data-dir='+str(directory/'profile-shot'), '--window-size=1400,1150',
                       '--screenshot='+str(output), f'http://localhost:{port}/guide?check=1']
            subprocess.run(command, check=True, capture_output=True, timeout=30)
            assert output.is_file() and output.stat().st_size > 1000
            print(json.dumps({'browser': 'Chromium', 'observations': observations, 'screenshot': output.name}))
        finally:
            server.close()


if __name__ == '__main__':
    main()
