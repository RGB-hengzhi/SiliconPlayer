#!/usr/bin/env python3
"""Prepare pinned arm64 WebTools in a private APFS cache, never launch a player.

This cache copy is pending review before introduction to the project scripts.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import time
import urllib.parse
import urllib.request
import zipfile
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone

CACHE = Path.home() / 'Library/Caches/SiliconPlayer/web-tools-build'
PROJECT = Path(__file__).resolve().parents[1]
BASE_PYTHON = Path(sys.executable).resolve()
TARGET = PROJECT / 'Vendor/WebTools'
YT_DLP_COMMIT = '3a08beaf031ab68f966401ead017ac81fe8486cf'
ARTIFACTS = {
    'yt-dlp.tar.gz': {'version': '2026.08.19', 'bytes': 6020567,
        'url': 'https://github.com/yt-dlp/yt-dlp/releases/download/2026.08.19/yt-dlp.tar.gz',
        'sha256': '072aad4f2a7604e92155f61a275a4752dc64046c8f6d90df3710525d94cd37c1'},
    'yt_dlp_ejs-0.8.0-py3-none-any.whl': {'version': '0.8.0', 'bytes': 53443,
        'url': 'https://github.com/yt-dlp/ejs/releases/download/0.8.0/yt_dlp_ejs-0.8.0-py3-none-any.whl',
        'sha256': '79300e5fca7f937a1eeede11f0456862c1b41107ce1d726871e0207424f4bdb4'},
    'deno-aarch64-apple-darwin.zip': {'version': '2.9.7', 'bytes': 38469316,
        'url': 'https://github.com/denoland/deno/releases/download/v2.9.7/deno-aarch64-apple-darwin.zip',
        'sha256': '5cd46d6268f6f78f5d88bdc7159d20bd44cdaa4b3303474839f87ec6fe7ae25c'},
    'pyinstaller.py': {'bytes':4739,
        'url':'https://raw.githubusercontent.com/yt-dlp/yt-dlp/3a08beaf031ab68f966401ead017ac81fe8486cf/bundle/pyinstaller.py',
        'sha256':'792b2e882d469b46e46f15707bf1869a2c043f7e89c79bc75f8725014482759a'},
    'THIRD_PARTY_LICENSES.txt': {'bytes':243550,
        'url':'https://raw.githubusercontent.com/yt-dlp/yt-dlp/3a08beaf031ab68f966401ead017ac81fe8486cf/THIRD_PARTY_LICENSES.txt',
        'sha256':'472aefe951c7db35e1657c1d13fd337140511ed6f2b329205105ad441c5a02b7'},
}
ARTIFACTS.update({
    'Deno-Cargo.lock':{'url':'https://raw.githubusercontent.com/denoland/deno/v2.9.7/Cargo.lock','bytes':294948,'sha256':'4b501f05a28bf12c453593f0b558407890575b5f34b9dcbb2dc8e172d58a0c95'},
    'Deno-MIT.txt':{'url':'https://raw.githubusercontent.com/denoland/deno/v2.9.7/LICENSE.md','bytes':1074,'sha256':'f62497fffecc0852960c8d3e6934b9db86d16396e9b604072e923892cae3a588'},
    'Deno-Node-types-MIT.txt':{'url':'https://raw.githubusercontent.com/denoland/deno/v2.9.7/cli/tsc/dts/node/LICENSE','bytes':1141,'sha256':'c2cfccb812fe482101a8f04597dfc5a9991a6b2748266c47ac91b6a5aae15383'},
    'Deno-Undici-types-MIT.txt':{'url':'https://raw.githubusercontent.com/denoland/deno/v2.9.7/cli/tsc/dts/node/undici/LICENSE','bytes':1090,'sha256':'a6db8096b2707bc0102d256917d4d33f298ba36d8c3f25de067a2b5bb379db27'},
    'TypeScript-6.0.3-Apache.txt':{'url':'https://raw.githubusercontent.com/microsoft/TypeScript/v6.0.3/LICENSE.txt','bytes':9197,'sha256':'a7d00bfd54525bc694b6e32f64c7ebcf5e6b7ae3657be5cc12767bce74654a47'},
    'V8-15.0.245.2-BSD.txt':{'url':'https://raw.githubusercontent.com/v8/v8/15.0.245.2/LICENSE','bytes':3093,'sha256':'6ab33af8774a0f396ee3aeeb761e3229057682d6f9fa7f572e390c2cb3a6e509'},
    'RustyV8-150.4.0-MIT.txt':{'url':'https://raw.githubusercontent.com/denoland/rusty_v8/v150.4.0/LICENSE','bytes':1078,'sha256':'1c6356fb751d45f0c53093ebf8a7f5e580e802f51999178e19d60f3ec39e147d'},
})
MACHO_MAGICS = {bytes.fromhex(x) for x in ['feedface','cefaedfe','feedfacf','cffaedfe','cafebabe','bebafeca','cafebabf','bfbafeca']}
OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))

def digest(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()

def save_json(path, value):
    Path(path).write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')

def child_env():
    # Preserve HOME as supplied by the environment, never redefine it.
    keep = {k: os.environ[k] for k in ('HOME','USER','LOGNAME','SYSTEMROOT') if k in os.environ}
    keep.update(PATH='/usr/bin:/bin:/usr/sbin:/sbin', LANG='en_US.UTF-8',
                TMPDIR=str(CACHE/'tmp'), PYTHONNOUSERSITE='1',
                PIP_CONFIG_FILE='/dev/null', PIP_DISABLE_PIP_VERSION_CHECK='1',
                PIP_NO_INPUT='1', DENO_DIR=str(CACHE/'deno-cache'),
                DENO_NO_UPDATE_CHECK='1', MACOSX_DEPLOYMENT_TARGET='14.0')
    return keep

def run(args, name, *, cwd=CACHE, timeout=600):
    print('Running', name, flush=True)
    result = subprocess.run([str(x) for x in args], cwd=cwd, env=child_env(),
                            text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            timeout=timeout)
    (CACHE/'logs'/f'{name}.log').write_text(result.stdout)
    if result.returncode:
        raise RuntimeError(f'{name} exited {result.returncode}:\n{result.stdout[-6000:]}')
    return result.stdout

def download(name, info, *, folder=None):
    target = (folder or CACHE/'downloads') / name
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.exists() and digest(target) == info['sha256']:
        if 'bytes' not in info or target.stat().st_size == info['bytes']:
            return target
    url = info['url']
    parsed = urllib.parse.urlsplit(url)
    if parsed.scheme != 'https' or parsed.hostname not in {'github.com','files.pythonhosted.org','raw.githubusercontent.com'}:
        raise RuntimeError(f'Unapproved download URL: {url}')
    limit = min(info.get('bytes', 64*1024*1024), 64*1024*1024)
    partial = target.with_name(target.name + '.part')
    for attempt in range(3):
        try:
            print('Downloading', name, flush=True)
            request = urllib.request.Request(url, headers={'User-Agent':'SiliconPlayer-WebTools-pinned/1'})
            with OPENER.open(request, timeout=45) as response, partial.open('wb') as output:
                total = 0
                while chunk := response.read(1024*1024):
                    total += len(chunk)
                    if total > limit:
                        raise RuntimeError(f'Download limit exceeded: {name}')
                    output.write(chunk)
            if 'bytes' in info and total != info['bytes']:
                raise RuntimeError(f'Unexpected download size: {name}')
            if digest(partial) != info['sha256']:
                raise RuntimeError(f'SHA256 mismatch: {name}')
            partial.replace(target)
            return target
        except Exception:
            partial.unlink(missing_ok=True)
            if attempt == 2:
                raise
            time.sleep(1)

def unpack_source():
    destination = CACHE/'source/yt-dlp-2026.08.19'
    if (destination/'.webtools-extracted').exists():
        return destination
    if destination.exists():
        shutil.rmtree(destination)
    destination.mkdir(parents=True)
    with tarfile.open(CACHE/'downloads/yt-dlp.tar.gz') as archive:
        members = archive.getmembers()
        if len(members) > 20000 or sum(m.size for m in members) > 128*1024*1024:
            raise RuntimeError('Oversized source archive')
        roots = {Path(m.name).parts[0] for m in members if Path(m.name).parts}
        strip = len(roots) == 1
        for member in members:
            pieces = Path(member.name).parts
            if not pieces or (strip and len(pieces) == 1):
                continue
            member.name = str(Path(*(pieces[1:] if strip else pieces)))
            if member.issym() or member.islnk() or not (member.isfile() or member.isdir()):
                raise RuntimeError('Unexpected linked or special source archive member')
            target = (destination/member.name).resolve()
            if not target.is_relative_to(destination.resolve()):
                raise RuntimeError('Source archive escaped destination')
            archive.extract(member, destination, filter='data')
    if not (destination/'pyproject.toml').exists():
        raise RuntimeError('Source archive layout is not the official project')
    (destination/'.webtools-extracted').write_text(ARTIFACTS['yt-dlp.tar.gz']['sha256'])
    return destination

def prepare_environment(source):
    import tomllib  # Build path requires approved Python 3.12; verify supports system Python 3.9.
    venv = CACHE/'venv'
    python = venv/'bin/python3'
    if not python.exists():
        run([BASE_PYTHON,'-m','venv','--copies',venv], 'venv-create')
    pyproject = tomllib.loads((source/'pyproject.toml').read_text())
    project = pyproject['project']
    groups = project['optional-dependencies']
    specs = groups['default'] + groups['pin'] + pyproject['dependency-groups']['pyinstaller']
    report_path = CACHE/'resolution-report.json'
    if not report_path.exists():
        run([python,'-m','pip','--isolated','install','--dry-run','--ignore-installed',
             '--only-binary=:all:','--index-url','https://pypi.org/simple',
             '--cache-dir',CACHE/'pip-cache','--report',report_path,*specs], 'resolve-dependencies')
    report = json.loads(report_path.read_text())
    downloads, requirements = [], []
    for item in report['install']:
        metadata, download_info = item['metadata'], item['download_info']
        name, version = metadata['name'], metadata['version']
        filename = Path(urllib.parse.urlsplit(download_info['url']).path).name
        if not filename.endswith('.whl'):
            raise RuntimeError('Build requires a non-wheel dependency: '+name)
        info = {'name':name,'version':version,'url':download_info['url'],
                'sha256':download_info['archive_info']['hashes']['sha256'],
                'metadata_license':metadata.get('license_expression') or metadata.get('license'),
                'scope':'build/runtime' if name.lower() not in {'pyinstaller','pyinstaller-hooks-contrib','altgraph','macholib','setuptools','packaging'} else 'build'}
        if name.lower().replace('_','-') == 'yt-dlp-ejs':
            official = ARTIFACTS['yt_dlp_ejs-0.8.0-py3-none-any.whl']
            if version != '0.8.0' or info['sha256'] != official['sha256']:
                raise RuntimeError('PyPI EJS wheel does not match official release')
            info.update(official)
            filename = 'yt_dlp_ejs-0.8.0-py3-none-any.whl'
        info['filename'] = filename
        downloads.append(info)
        requirements.append(f'{name}=={version} --hash=sha256:{info["sha256"]}')
    if sum(info.get('bytes', 64*1024*1024) for info in downloads) > 2*1024*1024*1024:
        raise RuntimeError('Dependency acquisition exceeds bounded planning budget')
    wheelhouse = CACHE/'wheelhouse'
    with ThreadPoolExecutor(max_workers=3) as pool:
        list(pool.map(lambda info: download(info['filename'],info,folder=wheelhouse), downloads))
    for info in downloads:
        info['bytes'] = (wheelhouse/info['filename']).stat().st_size
    if sum(info['bytes'] for info in downloads) > 512*1024*1024:
        raise RuntimeError('Wheelhouse exceeds size budget')
    lock = CACHE/'requirements.lock'
    lock.write_text('\n'.join(sorted(requirements))+'\n')
    save_json(CACHE/'dependency-downloads.json', downloads)
    run([python,'-m','pip','--isolated','install','--no-index','--find-links',wheelhouse,
         '--require-hashes','-r',lock], 'install-locked-dependencies')
    run([python,'-m','pip','--isolated','check'], 'dependency-check')
    run([python,'-c','import platform,sys; assert platform.machine()=="arm64"; assert sys.version_info[:2]==(3,12); import yt_dlp_ejs; print(sys.version); print(yt_dlp_ejs.__file__)'], 'venv-runtime')
    return python, downloads

def materialize_tree(source, target):
    """Copy all logical paths, dereference only links contained in source tree."""
    source = source.resolve()
    def visit(current, output, ancestors):
        resolved = current.resolve(strict=True)
        if not resolved.is_relative_to(source):
            raise RuntimeError('External runtime link: '+str(current))
        if resolved in ancestors:
            raise RuntimeError('Cyclic runtime directory link: '+str(current))
        if resolved.is_dir():
            output.mkdir(parents=True,exist_ok=True)
            for child in sorted(current.iterdir()):
                if not child.name.startswith('._'):
                    visit(child,output/child.name,ancestors|{resolved})
        elif resolved.is_file():
            output.parent.mkdir(parents=True,exist_ok=True)
            shutil.copyfile(resolved,output)
            output.chmod(stat.S_IMODE(resolved.stat().st_mode))
            if digest(resolved) != digest(output):
                raise RuntimeError('Materialized runtime hash mismatch')
        else:
            raise RuntimeError('Special runtime file: '+str(current))
    visit(source,target,set())

def is_macho(path):
    with path.open('rb') as f:
        return f.read(4) in MACHO_MAGICS

def inspect_macho(path, root):
    archs = subprocess.check_output(['/usr/bin/lipo','-archs',str(path)],text=True).strip().split()
    if archs != ['arm64']:
        if 'arm64' not in archs:
            raise RuntimeError('No arm64 slice: '+str(path))
        thin = path.with_name(path.name+'.arm64-tmp')
        subprocess.run(['/usr/bin/lipo',str(path),'-thin','arm64','-output',str(thin)],check=True)
        mode=stat.S_IMODE(path.stat().st_mode);thin.replace(path);path.chmod(mode)
        archs=subprocess.check_output(['/usr/bin/lipo','-archs',str(path)],text=True).strip().split()
    if archs != ['arm64']:
        raise RuntimeError('Runtime is not strictly arm64: '+str(path))
    subprocess.run(['/usr/bin/codesign','--force','--sign','-',str(path)],check=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    subprocess.run(['/usr/bin/codesign','--verify','--strict',str(path)],check=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    linked=subprocess.check_output(['/usr/bin/otool','-L',str(path)],text=True).splitlines()[1:]
    deps=[line.strip().split(' (compatibility')[0] for line in linked]
    commands=subprocess.check_output(['/usr/bin/otool','-l',str(path)],text=True)
    rpaths=re.findall(r'cmd LC_RPATH\s+cmdsize \d+\s+path (.*?) \(offset',commands)
    minimums=re.findall(r'cmd LC_BUILD_VERSION\s+cmdsize \d+\s+platform (?:\d+|macos)\s+minos ([\d.]+)',commands)
    minimums += re.findall(r'cmd LC_VERSION_MIN_MACOSX\s+cmdsize \d+\s+version ([\d.]+)',commands)
    if not minimums or any(tuple(int(v) for v in x.split('.'))>(14,0,0) for x in minimums):
        raise RuntimeError('Unexpected deployment target: '+str(path)+' '+repr(minimums))
    for p in rpaths:
        if p.startswith('/') and not p.startswith(('/usr/lib/','/System/Library/')):
            raise RuntimeError('Development rpath leaked: '+p)
    ids=re.findall(r'cmd LC_ID_DYLIB\s+cmdsize \d+\s+name (.*?) \(offset',commands)
    return {'path':str(path.relative_to(root)),'architectures':archs,'install_ids':ids,
            'dependencies':deps,'rpaths':rpaths,'minimum_macos':minimums,
            'signature':'verified-ad-hoc'}

def audit_dependency_closure(root, rows):
    executable=root/'yt-dlp/yt-dlp_macos'
    bypath={str((root/r['path']).resolve()):r for r in rows}
    main=next(r for r in rows if r['path']=='yt-dlp/yt-dlp_macos')
    edges=[]
    def expand(value,loader):
        if value.startswith('@loader_path'):
            return loader.parent/value.removeprefix('@loader_path/').removeprefix('@loader_path')
        if value.startswith('@executable_path'):
            return executable.parent/value.removeprefix('@executable_path/').removeprefix('@executable_path')
        return Path(value)
    for row in rows:
        loader=root/row['path']
        for dep in row['dependencies']:
            if dep in row['install_ids']:
                continue
            if dep.startswith(('/usr/lib/','/System/Library/')):
                edges.append({'from':row['path'],'dependency':dep,'resolved':'system'})
                continue
            if dep.startswith('@rpath/'):
                candidates=[expand(r,loader)/dep[len('@rpath/'):] for r in row['rpaths']]
                candidates += [expand(r,executable)/dep[len('@rpath/'):] for r in main['rpaths']]
            elif dep.startswith(('@loader_path','@executable_path')):
                candidates=[expand(dep,loader)]
            else:
                raise RuntimeError('Non-system absolute/unqualified runtime dependency: '+dep)
            found=next((c.resolve() for c in candidates if c.is_file()),None)
            if found is None or not found.is_relative_to(root.resolve()) or str(found) not in bypath:
                raise RuntimeError('Unresolved native dependency: '+row['path']+' -> '+dep)
            edges.append({'from':row['path'],'dependency':dep,'resolved':str(found.relative_to(root.resolve()))})
    return edges

def collect_licenses(source, stage, python):
    target=stage/'licenses';target.mkdir()
    shutil.copyfile(source/'LICENSE',target/'yt-dlp-Unlicense.txt')
    shutil.copyfile(source/'THIRD_PARTY_LICENSES.txt',target/'yt-dlp-THIRD_PARTY_LICENSES.txt')
    shutil.copyfile(Path(sys.base_prefix)/'lib/python3.12/LICENSE.txt',target/'Python-LICENSE.txt')
    script='import importlib.metadata,json; print(json.dumps([{ "name": d.metadata["Name"], "version":d.version,"files":[str(d.locate_file(f)) for f in (d.files or []) if any(k in str(f).lower() for k in ("license","copying","notice","authors")) and ".dist-info/" in str(f)]} for d in importlib.metadata.distributions()]))'
    entries=json.loads(run([python,'-c',script],'license-discovery'))
    for entry in entries:
        for n,raw in enumerate(entry['files']):
            p=Path(raw)
            if p.is_file():
                output=target/'python-packages'/f'{entry["name"]}-{entry["version"]}'/f'{n:02d}-{p.name}'
                output.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(p,output)
    deno_sources={}
    for name,info in ARTIFACTS.items():
        if name.startswith(('Deno-','TypeScript-','V8-','RustyV8-')):
            output=target/'deno'/name;output.parent.mkdir(exist_ok=True)
            shutil.copyfile(CACHE/'downloads'/name,output);deno_sources[name]=info
    save_json(target/'deno/source-index.json',{'coverage':'partial top-level and known notices only',
              'publication_certification':False,'sources':deno_sources,
              'remaining':'Accurate built Rust/V8 third-party license closure before public distribution. Cargo.lock is source evidence, not a compiled SBOM.'})
    save_json(target/'python-package-index.json',entries)

def validate_runtime(stage, python, source, label):
    executable=stage/'yt-dlp/yt-dlp_macos'
    args=[executable,'--ignore-config','--no-plugin-dirs','--no-remote-components',
          '--no-js-runtimes','--js-runtimes',f'deno:{stage/"deno"}',
          '--no-cookies-from-browser','--no-update','--no-cache-dir']
    version=run([*args,'--version'],label+'-yt-version',timeout=30).strip()
    if version!='2026.08.19':raise RuntimeError('Frozen yt-dlp version mismatch')
    # No URL: detect runtime/optional library versions without media network I/O.
    result=subprocess.run([str(x) for x in [*args,'--verbose']],cwd=CACHE,env=child_env(),
                          stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=30)
    (CACHE/'logs'/f'{label}-yt-diagnostics.log').write_text(result.stdout)
    if result.returncode!=2 or 'yt_dlp_ejs-0.8.0' not in result.stdout or 'deno-2.9.7' not in result.stdout:
        raise RuntimeError('Frozen EJS/runtime version detection failed: '+result.stdout[-3000:])
    core=stage/'yt-dlp/_internal/yt_dlp_ejs/yt/solver/core.min.js'
    lib=stage/'yt-dlp/_internal/yt_dlp_ejs/yt/solver/lib.min.js'
    wheel=CACHE/'downloads/yt_dlp_ejs-0.8.0-py3-none-any.whl'
    with zipfile.ZipFile(wheel) as archive:
        for p in (core,lib):
            expected=archive.read('yt_dlp_ejs/yt/solver/'+p.name)
            if p.read_bytes()!=expected:raise RuntimeError('Frozen EJS data differs from official wheel')
    request={'type':'preprocessed','preprocessed_player':'_result.n = n => n.split(\"\").reverse().join(\"\"); _result.sig = s => s.slice(1);',
             'requests':[{'type':'n','challenges':['中文ABC']},{'type':'sig','challenges':['abcdef']}]}
    code=lib.read_text()+'\nObject.assign(globalThis, lib);\n'+core.read_text()+'\nconsole.log(JSON.stringify(jsc('+json.dumps(request,ensure_ascii=False)+')));\n'
    deno_args=[stage/'deno','run','--ext=js','--no-code-cache','--no-prompt','--no-remote',
               '--no-lock','--node-modules-dir=none','--no-config','--no-npm','--cached-only','-']
    result=subprocess.run([str(x) for x in deno_args],input=code,cwd=CACHE,env=child_env(),
                          stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,timeout=30)
    if result.returncode or result.stderr:raise RuntimeError('Offline EJS/Deno execution failed: '+result.stderr)
    actual=json.loads(result.stdout)
    expected={'type':'result','responses':[{'type':'result','data':{'中文ABC':'CBA文中'}},{'type':'result','data':{'abcdef':'bcdef'}}]}
    if actual!=expected:raise RuntimeError('Offline EJS solver output mismatch')
    return {'label':label,'directory':str(stage),'yt_dlp_version':version,
            'frozen_cli_detected_ejs':'0.8.0','frozen_cli_detected_deno':'2.9.7',
            'ejs_core_sha256':digest(core),'ejs_lib_sha256':digest(lib),
            'ejs_data_matches_official_wheel':True,'offline_ejs_deno_output':actual,
            'offline_ejs_scope':'Bundled scripts perform synthetic preprocessed n/signature operations; does not prove current website player parsing.',
            'no_url_or_network_media_invocation':True,'deno_permissions':'no remote/npm/config, cached-only, no explicit permissions'}

def inventory(root):
    rows=[]
    for path in sorted(root.rglob('*')):
        if any(part.startswith('._') for part in path.relative_to(root).parts):
            continue
        if path.is_symlink():raise RuntimeError('Release tree still contains symbolic link: '+str(path))
        if path.is_file() and path.name!='manifest.json':
            rows.append({'path':str(path.relative_to(root)),'sha256':digest(path),'bytes':path.stat().st_size,'executable':is_macho(path)})
    return rows

def clean_appledouble(root):
    for path in sorted(root.rglob('._*'),reverse=True):
        if path.is_file() or path.is_symlink():path.unlink()
        elif path.is_dir():path.rmdir()

def verify_tree(root):
    manifest=json.loads((root/'manifest.json').read_text())
    expected={r['path']:r for r in manifest['files']}
    actual={r['path']:r for r in inventory(root)}
    if expected!=actual:raise RuntimeError('WebTools inventory mismatch')
    if any(root.rglob('._*')):raise RuntimeError('AppleDouble sidecar remains in release directory')
    for entry in [root/'yt-dlp/yt-dlp_macos',root/'deno']:
        if not os.access(entry,os.X_OK):raise RuntimeError('Runtime entry point is not executable')
    for row in manifest['macho_files']:
        path=root/row['path']
        arch=subprocess.check_output(['/usr/bin/lipo','-archs',str(path)],text=True).strip()
        if arch!='arm64':raise RuntimeError('Non-arm64 release file: '+row['path'])
        subprocess.run(['/usr/bin/codesign','--verify','--strict',str(path)],check=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    if audit_dependency_closure(root,manifest['macho_files'])!=manifest['native_dependency_edges']:
        raise RuntimeError('Native dependency closure changed')
    print(f'Verified WebTools: {len(actual)} files, {len(manifest["macho_files"])} arm64 Mach-O files',flush=True)

def build():
    if platform.machine()!='arm64' or sys.version_info[:3]!=(3,12,14):
        raise RuntimeError('Building requires native arm64 Python 3.12.14. Supply --build-python /absolute/path/to/python3; --verify supports system Python 3.9.')
    if (TARGET/'manifest.json').exists():
        verify_tree(TARGET)
        print('Existing WebTools verified; no rebuild or downloads performed.',flush=True)
        return
    for path in [CACHE,CACHE/'tmp',CACHE/'logs',CACHE/'downloads']:
        path.mkdir(parents=True,exist_ok=True)
    with ThreadPoolExecutor(max_workers=3) as pool:
        list(pool.map(lambda pair:download(*pair),ARTIFACTS.items()))
    source=unpack_source()
    (source/'bundle').mkdir(exist_ok=True)
    shutil.copyfile(CACHE/'downloads/pyinstaller.py',source/'bundle/pyinstaller.py')
    shutil.copyfile(CACHE/'downloads/THIRD_PARTY_LICENSES.txt',source/'THIRD_PARTY_LICENSES.txt')
    python,dependencies=prepare_environment(source)
    run([python,'devscripts/make_lazy_extractors.py'],'lazy-extractors',cwd=source)
    run([python,'-m','bundle.pyinstaller','--onedir','--target-arch','arm64',
         '--workpath',CACHE/'pyinstaller-work','--distpath',CACHE/'dist','--noconfirm'],
        'pyinstaller-build',cwd=source,timeout=1200)
    stage=CACHE/'release-stage'
    if stage.exists():shutil.rmtree(stage)
    stage.mkdir()
    materialize_tree(CACHE/'dist/yt-dlp_macos',stage/'yt-dlp')
    with zipfile.ZipFile(CACHE/'downloads/deno-aarch64-apple-darwin.zip') as archive:
        if archive.namelist()!=['deno'] or archive.getinfo('deno').file_size>256*1024*1024:
            raise RuntimeError('Unexpected Deno release archive contents')
        with archive.open('deno') as inp,(stage/'deno').open('wb') as out:shutil.copyfileobj(inp,out)
    (stage/'deno').chmod(0o755)
    macho=[]
    for p in sorted(stage.rglob('*')):
        if p.is_file() and is_macho(p):macho.append(inspect_macho(p,stage))
    if not macho:raise RuntimeError('No native files audited')
    native_edges=audit_dependency_closure(stage,macho)
    collect_licenses(source,stage,python)
    runtime_validation=[validate_runtime(stage,python,source,'original')]
    version=runtime_validation[0]['yt_dlp_version']
    deno_version=run([stage/'deno','--version'],'deno-version',timeout=30).strip()
    if not deno_version.startswith('deno 2.9.7 '):raise RuntimeError('Deno version mismatch')
    relocated=CACHE/'搬迁 中文 空格/WebTools'
    if relocated.exists():shutil.rmtree(relocated)
    materialize_tree(stage,relocated)
    runtime_validation.append(validate_runtime(relocated,python,source,'relocated-utf8-spaces'))
    save_json(stage/'runtime-validation.json',runtime_validation)
    shutil.copyfile(CACHE/'requirements.lock',stage/'requirements.lock')
    save_json(stage/'downloads.json',{'official_artifacts':ARTIFACTS,'python_packages':dependencies})
    manifest={'schema':1,'generated_utc':datetime.now(timezone.utc).isoformat(),
              'architecture':'arm64','scope':'dependency bundle only; no webpage playback acceptance',
              'permission_contract':'executable flags describe native code files; exFAT mode bits are not canonical; runtime entry points must be executable',
              'distribution_status':'local development/test only; no public-distribution license certification',
              'license_coverage':{'yt_dlp_python':'included collected source/wheel notices; full GPL product distribution review remains separate',
                                  'deno':'partial known notices/source lock; exact compiled Rust/V8 third-party license closure incomplete'},
              'minimum_macos_declared':'14.0','minimum_macos_execution_test':'macOS 27 only; macOS 14 not independently run',
              'nested_code_bundles':[str(p.relative_to(stage)) for p in stage.rglob('*') if p.is_dir() and p.suffix in {'.framework','.app','.bundle'}],
              'yt_dlp_version':version,'yt_dlp_release_tag_commit':YT_DLP_COMMIT,
              'yt_dlp_embedded_release_git_head':re.search(r"RELEASE_GIT_HEAD\s*=\s*['\"]([^'\"]+)", (source/'yt_dlp/version.py').read_text()).group(1),
              'ejs_version':'0.8.0','deno_version':deno_version,
              'build_python':{'version':sys.version,'executable':str(BASE_PYTHON),'architecture':platform.machine(),'sha256':digest(BASE_PYTHON.resolve())},
              'build_script_sha256':digest(Path(__file__)),
              'build_entry':'python -m bundle.pyinstaller --onedir --target-arch arm64',
              'official_artifacts':ARTIFACTS,'dependencies':dependencies,'macho_files':macho,
              'native_dependency_edges':native_edges,'runtime_validation':runtime_validation,'files':inventory(stage)}
    save_json(stage/'manifest.json',manifest)
    verify_tree(stage)
    if TARGET.exists():
        raise RuntimeError('New Vendor/WebTools already exists; do not overwrite without review')
    pending=TARGET.with_name('WebTools.incoming')
    if pending.exists():raise RuntimeError('Pending output exists; inspect instead of deleting it')
    materialize_tree(stage,pending)
    clean_appledouble(pending)
    verify_tree(pending)
    runtime_validation.append(validate_runtime(pending,python,source,'exfat-project-copy'))
    save_json(pending/'runtime-validation.json',runtime_validation)
    manifest['runtime_validation']=runtime_validation
    manifest['files']=inventory(pending)
    save_json(pending/'manifest.json',manifest)
    clean_appledouble(pending)
    verify_tree(pending)
    pending.replace(TARGET)
    print('Published new dependency directory:',TARGET,flush=True)

def main():
    global BASE_PYTHON
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--verify',action='store_true',help='Read-only verification; supports system Python 3.9.')
    parser.add_argument('--build-python',help='Absolute path to approved native arm64 Python 3.12.14; used only for building.')
    parser.add_argument('--build-python-sha256',help='Optional approved executable SHA256, checked before running the build interpreter.')
    args=parser.parse_args()
    if args.verify:
        verify_tree(TARGET)
        return
    if args.build_python_sha256 and not args.build_python:
        parser.error('--build-python-sha256 requires --build-python')
    if args.build_python:
        candidate=Path(args.build_python)
        if not candidate.is_absolute() or not candidate.is_file() or not os.access(candidate,os.X_OK):
            raise RuntimeError('--build-python must be an existing executable absolute path')
        actual_sha=digest(candidate.resolve())
        if args.build_python_sha256 and actual_sha!=args.build_python_sha256:
            raise RuntimeError('Build interpreter SHA256 mismatch')
        info=subprocess.run([str(candidate),'-I','-c',
            'import json,sys,platform; print(json.dumps({"version":list(sys.version_info[:3]),"machine":platform.machine()}))'],
            env=child_env(),text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=15)
        if info.returncode:
            raise RuntimeError('Cannot query build interpreter: '+info.stderr[-1000:])
        identity=json.loads(info.stdout)
        if identity!={'version':[3,12,14],'machine':'arm64'}:
            raise RuntimeError('Build interpreter must be native arm64 Python 3.12.14: '+repr(identity))
        print('Approved build runtime: Python 3.12.14 arm64, SHA256 '+actual_sha,flush=True)
        if candidate.resolve()!=Path(sys.executable).resolve():
            os.execv(str(candidate),[str(candidate),str(Path(__file__).resolve()),*sys.argv[1:]])
        BASE_PYTHON=candidate.resolve()
    build()

if __name__=='__main__':
    try:main()
    except (RuntimeError,ValueError,OSError,subprocess.SubprocessError) as error:
        print('WebTools: '+str(error),file=sys.stderr)
        sys.exit(1)
