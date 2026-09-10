"""Download the pinned CUDA runtime wheels required by our cached PyTorch wheel."""
from pathlib import Path
import hashlib
import json
import re
import subprocess
import zipfile

cache = Path('/opt/gs/cache/training')
cache.mkdir(parents=True, exist_ok=True)
TUNA = 'https://pypi.tuna.tsinghua.edu.cn'

torch_wheel = next(cache.glob('torch-*.whl'))
with zipfile.ZipFile(torch_wheel) as wheel:
    metadata = wheel.read(next(n for n in wheel.namelist() if n.endswith('.dist-info/METADATA'))).decode()
requirements = re.findall(r'Requires-Dist: ((?:nvidia-[\w-]+|triton))\s*(?:\(==|==)([\d.]+)', metadata)


def sha256_file(path):
    digest = hashlib.sha256()
    with path.open('rb') as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def pypi_file(name, version):
    last_error = None
    for url in (
        f'{TUNA}/pypi/{name}/{version}/json',
        f'https://pypi.org/pypi/{name}/{version}/json',
    ):
        try:
            data = json.loads(subprocess.check_output([
                'curl', '-4', '-fsSL', '--connect-timeout', '10',
                '--max-time', '45', '--retry', '2', url,
            ]))
            break
        except subprocess.CalledProcessError as error:
            last_error = error
    else:
        raise last_error
    candidates = [
        item for item in data['urls']
        if item['filename'].endswith('.whl')
        and 'manylinux' in item['filename']
        and 'x86_64' in item['filename']
        and ('-py3-' in item['filename'] or '-cp310-' in item['filename'])
    ]
    if not candidates:
        raise RuntimeError(f'no wheel for {name}=={version}')
    return candidates[0]


entries = []
for name, version in requirements:
    info = pypi_file(name, version)
    dest = cache / info['filename']
    aria = Path(str(dest) + '.aria2')
    expect = info['digests']['sha256']
    complete = dest.exists() and not aria.exists() and dest.stat().st_size == info['size']
    if complete:
        digest = sha256_file(dest)
        if digest == expect:
            print('HAVE', dest.name, flush=True)
            continue
        print('BADHASH', dest.name, digest, 'expected', expect, flush=True)
        dest.unlink()
    official = info['url']
    tuna_url = official.replace('https://files.pythonhosted.org', TUNA)
    entries.append(
        f'{tuna_url}\n'
        f'  url={official}\n'
        f'  out={info["filename"]}\n'
        f'  checksum=sha-256={expect}\n'
    )
    print('DOWNLOAD', name, version, info['size'], info['filename'], flush=True)

manifest = cache / 'cuda-downloads.txt'
manifest.write_text(''.join(entries))
if entries:
    subprocess.run([
        'aria2c', '-c', '-x', '8', '-s', '8', '-j', '3',
        '--file-allocation=none', '--disable-ipv6=true',
        '--max-tries=0', '--retry-wait=5', '--timeout=60',
        '--summary-interval=15', '--console-log-level=notice',
        '--download-result=full',
        '-d', str(cache), '-i', str(manifest),
    ], check=True)
print('CUDA_WHEELS_READY', flush=True)
