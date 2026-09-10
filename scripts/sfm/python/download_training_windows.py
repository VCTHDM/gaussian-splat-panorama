"""Use the existing Windows proxy to fetch the official pinned CUDA wheels."""
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor
import hashlib
import os
import shutil
import subprocess

linux = Path(r'\\wsl.localhost\GS-Ubuntu2204\opt\gs\cache\training')
cache = Path(__file__).resolve().parents[3] / 'cache' / 'training-wheels'
cache.mkdir(parents=True, exist_ok=True)
entries = []
for line in (linux / 'cuda-downloads.txt').read_text().splitlines():
    if line.startswith('https:'):
        entries.append({'url': line})
    elif line.strip().startswith('out='):
        entries[-1]['name'] = line.strip()[4:]
    elif line.strip().startswith('checksum='):
        entries[-1]['sha256'] = line.strip().split('=', 2)[2]

def download(entry):
    dest = cache / entry['name']
    command = ['curl.exe', '-fL', '--retry', '3', '--connect-timeout', '20', '-C', '-',
               '--silent', '--show-error', '-o', str(dest)]
    proxy = os.environ.get('HTTP_PROXY')
    if proxy:
        command += ['--proxy', proxy]
    print('FETCH', entry['name'], flush=True)
    subprocess.run(command + [entry['url']], check=True)
    with dest.open('rb') as file:
        digest = hashlib.file_digest(file, 'sha256').hexdigest()
    if digest != entry['sha256']:
        raise RuntimeError(f'Hash mismatch: {dest.name}')
    shutil.copy2(dest, linux / dest.name)
    print('READY', dest.name, dest.stat().st_size, flush=True)

with ThreadPoolExecutor(max_workers=3) as pool:
    list(pool.map(download, entries))
print('WINDOWS_DOWNLOAD_READY', flush=True)
