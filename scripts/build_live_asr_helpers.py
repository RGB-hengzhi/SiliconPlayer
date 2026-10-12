#!/usr/bin/env python3
"""Draft: explicit bootstrap/build/finalize phases; no import-time actions."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import signal
import stat
import subprocess
import time


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def clean_path(value):
    p = Path(value)
    require(p.is_absolute() and '\x00' not in str(p) and not any(x.startswith('._') for x in p.parts), 'Absolute non-AppleDouble path required')
    return p


def regular(root, relative):
    root = clean_path(root)
    rel = Path(relative)
    require(not rel.is_absolute() and rel.parts and all(x not in ('.', '..') and not x.startswith('._') for x in rel.parts), 'Invalid relative path')
    p = root
    require(not root.is_symlink(), 'Root symlink rejected')
    for part in rel.parts:
        p = p / part
        require(not p.is_symlink(), 'Symlink rejected: ' + str(p))
    require(stat.S_ISREG(p.stat().st_mode), 'Regular file required: ' + str(p))
    return p


def digest(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def read_json(path, bound=2 * 1024 * 1024):
    p = clean_path(path)
    require(not p.is_symlink() and p.is_file() and p.stat().st_size <= bound, 'Invalid JSON file')
    def pairs(items):
        out = {}
        for key, value in items:
            require(key not in out, 'Duplicate JSON key')
            out[key] = value
        return out
    return json.loads(p.read_text(), object_pairs_hook=pairs)


def save(path, value):
    path = Path(path)
    require(not path.exists(), 'Existing output preserved: ' + str(path))
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open('x') as stream:
        stream.write(json.dumps(value, ensure_ascii=False, indent=2) + '\n')


def fresh(path):
    p = clean_path(path)
    require(not p.exists(), 'Fresh directory required: ' + str(p))
    p.mkdir(parents=True)
    return p


def verify_row(path, row):
    require(not Path(path).is_symlink() and stat.S_ISREG(Path(path).stat().st_mode), 'Materialized file required')
    if 'bytes' in row:
        require(Path(path).stat().st_size == row['bytes'], 'Byte size differs: ' + str(path))
    require(digest(path) == row['sha256'], 'SHA differs: ' + str(path))


def copy_row(source, destination, row):
    verify_row(source, row)
    require(not destination.exists(), 'Copy target exists')
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, destination)
    destination.chmod(0o644)
    verify_row(destination, row)


def inventory(root):
    rows = []
    for p in sorted(root.rglob('*')):
        require(not p.is_symlink(), 'Inventory symlink rejected')
        if p.is_file() and not any(s.startswith('._') for s in p.relative_to(root).parts):
            rows.append({'path':str(p.relative_to(root)), 'bytes':p.stat().st_size, 'sha256':digest(p)})
    return rows


def alive_group(pgid):
    try:
        os.killpg(pgid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def fixed_environment(tmp=None):
    env = {'PATH':'/usr/bin:/bin:/usr/sbin:/sbin','LANG':'en_US.UTF-8','LC_ALL':'en_US.UTF-8'}
    # Preserve original identity values; never repurpose the user's HOME.
    for key in ('HOME','USER','LOGNAME'):
        if key in os.environ:
            env[key] = os.environ[key]
    if tmp is not None:
        env['TMPDIR'] = str(tmp) + '/'
    return env


def cleanup_group(pgid):
    for sig, grace in ((signal.SIGTERM, 1), (signal.SIGKILL, 2)):
        if alive_group(pgid):
            try:
                os.killpg(pgid, sig)
            except ProcessLookupError:
                pass
        end = time.monotonic() + grace
        while alive_group(pgid) and time.monotonic() < end:
            time.sleep(.025)
    return not alive_group(pgid)


def run(argv, report, label, env, timeout=120):
    require(all(isinstance(x, str) for x in argv), 'String argv required')
    stdout, stderr = report/(label+'.stdout'), report/(label+'.stderr')
    start = time.monotonic()
    with stdout.open('xb') as out, stderr.open('xb') as err:
        proc = subprocess.Popen(argv, stdout=out, stderr=err, env=env, start_new_session=True)
        forced = False; code = None
        try:
            code = proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            forced = True
            cleanup_group(proc.pid)
            try:
                code = proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                code = None
    remaining = alive_group(proc.pid)
    if remaining:
        forced = True
        cleanup_group(proc.pid)
    result = {'argv':argv, 'pid':proc.pid, 'pgid':proc.pid, 'exitCode':code,
              'elapsedSeconds':time.monotonic()-start, 'forcedCleanup':forced,
              'ownedGroupGone':not alive_group(proc.pid), 'stdoutSHA256':digest(stdout), 'stderrSHA256':digest(stderr)}
    save(report/(label+'.json'), result)
    require(code == 0 and not forced and result['ownedGroupGone'], label+' did not finish naturally')
    return stdout.read_text()


def bootstrap(args, pins, report):
    acquisition = clean_path(args.acquisition_root)
    headers = clean_path(args.ffmpeg_headers_root)
    before = {str(args.pins):digest(args.pins)}
    # Check all 42 acquisition assets, but do not ship unneeded upstream tools.
    for row in pins['acquisitionFiles']:
        p = regular(acquisition, row['path']); verify_row(p, row); before[str(p)] = row['sha256']
    for row in pins['pcmHeaders']:
        p = regular(headers, str(Path(row['path']).relative_to('headers')))
        verify_row(p, row); before[str(p)] = row['sha256']
    target = fresh(args.target)
    for row in pins['runtimeLibraries']:
        copy_row(regular(acquisition, row['path']), target/row['relativePath'], row)
    row = pins['sherpaHeader']
    copy_row(regular(acquisition, row['path']), target/row['relativePath'], row)
    for row in pins['pcmHeaders']:
        copy_row(regular(headers, str(Path(row['path']).relative_to('headers'))), target/row['path'], row)
    licenses = []
    ready = False
    if args.license_manifest:
        data = read_json(args.license_manifest)
        before[str(args.license_manifest)] = digest(args.license_manifest)
        require(data.get('schema') == 1 and isinstance(data.get('files'), list), 'License manifest schema')
        ready = data.get('distributionReady') is True
        if ready:
            require(set(data.get('reviewedComponents', [])) >= {'sherpa-onnx','onnxruntime','model','ffmpeg-closure'}, 'Incomplete distribution review')
        seen = set()
        for row in data['files']:
            require(row['path'] not in seen, 'Duplicate license path'); seen.add(row['path'])
            src = regular(clean_path(args.licenses_root), row['path'])
            copy_row(src, target/'licenses'/row['path'], row)
            before[str(src)] = row['sha256']; licenses.append(row)
        require(not ready or licenses, 'Complete license payload missing')
    require(not args.distribution or ready, 'Distribution inputs pending; local prototype can proceed')
    model_target = None
    if args.model_output:
        model_target = fresh(args.model_output)
        model_base = acquisition/pins['modelDirectoryName']
        for row in pins['modelFiles'] + [pins['modelREADME']]:
            copy_row(regular(model_base, row['relativePath']), model_target/row['relativePath'], row)
        save(model_target/'model-manifest.json', {'schema':1,'profileID':pins['profileID'],
            'files':[{ 'path':r['relativePath'], 'bytes':r['bytes'], 'sha256':r['sha256']} for r in pins['modelFiles']],
            'configuration':{'sampleRate':16000,'featureDimension':80,'threads':2,'provider':'cpu','modelingUnit':'cjkchar','decodingMethod':'greedy_search'},
            'README':pins['modelREADME'], 'distributionReady':ready})
    after = {name:digest(Path(name)) for name in before}
    require(before == after, 'Bootstrap input changed')
    files = inventory(target)
    save(target/'manifest.json', {'schema':1, 'profileID':pins['profileID'], 'files':files,
        'packagePinsSHA256':digest(args.pins), 'acquisitionManifest':'42 fixed acquisition files',
        'distributionReady':ready, 'licenseFiles':licenses, 'localPrototype':not ready})
    save(report/'bootstrap.json', {'status':'passed-bootstrap-only','inputsBefore':before,'inputsAfter':after,
        'target':str(target),'modelTarget':str(model_target) if model_target else None,'files':files,'AppGroups':0})


def vendor_files(vendor, pins):
    data = read_json(vendor/'manifest.json')
    require(data.get('schema') == 1 and data.get('profileID') == pins['profileID'], 'Vendor profile schema')
    actual = inventory(vendor)
    actual = [r for r in actual if r['path'] != 'manifest.json']
    require(actual == data['files'], 'Vendor full inventory mismatch')
    return data


def abi(path, env, report, label):
    arch = run(['/usr/bin/lipo','-archs',str(path)],report,label+'-arch',env,30).strip()
    require(arch == 'arm64', 'Thin arm64 required')
    loads = run(['/usr/bin/otool','-L',str(path)],report,label+'-loads',env,30)
    dependencies = [line.strip().split(' (')[0] for line in loads.splitlines()[1:]]
    commands = run(['/usr/bin/otool','-l',str(path)],report,label+'-commands',env,30)
    rpaths = re.findall(r'cmd LC_RPATH\s+cmdsize \d+\s+path (.*?) \(offset', commands)
    minimum = re.findall(r'\bminos ([0-9.]+)', commands)
    require(minimum, 'LC_BUILD_VERSION missing')
    return {'path':str(path),'architecture':arch,'loads':dependencies,'rpaths':rpaths,'minimumOS':minimum}


def build(args, pins, report):
    project, vendor = clean_path(args.project_root), clean_path(args.vendor_root)
    bundle = clean_path(args.staging_app); contents = bundle/'Contents'
    require(contents.is_dir() and not bundle.is_symlink(), 'Existing owned staging bundle required')
    require(all(p.is_dir() and not p.is_symlink() for p in (contents, contents/'Frameworks', contents/'Resources')), 'Materialized staging directories required')
    require(digest(regular(project,'Vendor/manifest.json')) == pins['VendorManifestSHA256'], 'FFmpeg manifest differs')
    require(digest(regular(project,'Vendor/tools/manifest.json')) == pins['VendorToolsManifestSHA256'], 'Tools manifest differs')
    v = vendor_files(vendor, pins)
    require(not args.distribution or v['distributionReady'], 'Distribution licenses pending')
    work = fresh(args.work_directory)
    (work/'tmp').mkdir()
    env = fixed_environment(work/'tmp')
    save(report/'environment.json',env)
    filesystem = run(['/bin/df','-P',str(work)],report,'work-volume',env,30).splitlines()
    require(len(filesystem)==2, 'Work volume lookup')
    volume = run(['/usr/sbin/diskutil','info','-plist',filesystem[1].split()[0]],report,'work-filesystem',env,30)
    require(plistlib.loads(volume.encode()).get('FilesystemType')=='apfs', 'APFS work required')
    sdk = run(['/usr/bin/xcrun','--sdk','macosx','--show-sdk-path'],report,'sdk-path',env,30).strip()
    run(['/usr/bin/xcrun','--sdk','macosx','--show-sdk-version'],report,'sdk-version',env,30)
    run(['/usr/bin/xcrun','clang','--version'],report,'clang-version',env,30)
    sources = {'pcm':regular(project,'Sources/MediaPCMPTS/main.c'), 'recognizer':regular(project,'Sources/OnlineASRService/main.c')}
    require(digest(sources['pcm'])==pins['pcmSourceSHA256'] and digest(sources['recognizer'])==pins['recognizerSourceSHA256'],'C source differs')
    before = {str(p):digest(p) for p in sources.values()}
    for p in (args.pins, vendor/'manifest.json', project/'Vendor/manifest.json', project/'Vendor/tools/manifest.json'):
        before[str(p)]=digest(p)
    for row in pins['pcmLibraries']:
        name=Path(row['path']).name; p=regular(contents,'Frameworks/'+name)
        verify_row(p,row); before[str(p)]=row['sha256']
    output = contents/'Resources/LiveASR'
    require(not output.exists(), 'Existing LiveASR packaging preserved')
    helpers=output/'Helpers'; private=helpers/'runtime-libs';private.mkdir(parents=True)
    for row in pins['runtimeLibraries']:
        copy_row(regular(vendor,row['relativePath']),private/Path(row['relativePath']).name,row)
    for row in v['licenseFiles']:
        copy_row(regular(vendor,'licenses/'+row['path']),contents/'Resources/Licenses/LiveASR'/row['path'],row)
    header_root=vendor/'headers'; include_root=vendor/'include'
    for row in v['files']:
        before[str(regular(vendor,row['path']))]=row['sha256']
    base=['/usr/bin/xcrun','clang','-std=c11','-O2','-target','arm64-apple-macos14.0','-isysroot',sdk]
    pcm=helpers/'media-pcm-pts'; service=helpers/'online-asr-service'
    libs=[str(contents/'Frameworks'/name) for name in ('libavformat.63.dylib','libavcodec.63.dylib','libavutil.61.dylib','libswresample.7.dylib')]
    try:
        run(base+['-I',str(header_root),str(sources['pcm'])]+libs+['-Wl,-rpath,@executable_path/../../../Frameworks','-o',str(pcm)],report,'compile-pcm',env)
    finally:
        if pcm.is_file(): shutil.copyfile(pcm,report/pcm.name)
    try:
        run(base+['-I',str(include_root),str(sources['recognizer']),'-L',str(private),'-lsherpa-onnx-c-api','-Wl,-rpath,@executable_path/runtime-libs','-o',str(service)],report,'compile-service',env)
    finally:
        if service.is_file(): shutil.copyfile(service,report/service.name)
    pcm.chmod(0o755);service.chmod(0o755)
    snapshots=[abi(p,env,report,'abi-'+str(i)) for i,p in enumerate([pcm,service]+sorted(p for p in private.iterdir() if not any(s.startswith('._') for s in p.parts)))]
    require(snapshots[0]['rpaths']==['@executable_path/../../../Frameworks'],'PCM rpath differs')
    require(snapshots[1]['rpaths']==['@executable_path/runtime-libs'],'Service rpath differs')
    require(snapshots[0]['minimumOS']==['14.0'] and snapshots[1]['minimumOS']==['14.0'],'Helper deployment differs')
    for row in snapshots:
        require(all(x.startswith(('@rpath/','@loader_path/','/usr/lib/','/System/Library/')) for x in row['loads']),'Development load path rejected')
    if args.model_directory:
        model=clean_path(args.model_directory);data=read_json(model/'model-manifest.json')
        before[str(model/'model-manifest.json')]=digest(model/'model-manifest.json')
        require(data['schema']==1 and data['profileID']==pins['profileID'],'Model manifest differs')
        wanted=[{'path':r['relativePath'],'bytes':r['bytes'],'sha256':r['sha256']} for r in pins['modelFiles']]
        require(data['files']==wanted,'Model pins differ')
        destination=output/'Model';destination.mkdir()
        for row in wanted:
            source=regular(model,row['path']);copy_row(source,destination/row['path'],row);before[str(source)]=row['sha256']
        row=pins['modelREADME'];source=regular(model,'README.md');copy_row(source,destination/'README.md',row);before[str(source)]=row['sha256']
        shutil.copyfile(regular(model,'model-manifest.json'),destination/'model-manifest.json')
    after={name:digest(Path(name)) for name in before};require(before==after,'Build inputs changed')
    receipt={'schema':1,'status':'passed-compile-only','profileID':pins['profileID'],'pcmSourceSHA256':pins['pcmSourceSHA256'],
        'recognizerSourceSHA256':pins['recognizerSourceSHA256'],'packagePinsSHA256':digest(args.pins),'inputsBefore':before,'inputsAfter':after,
        'ABI':snapshots,'distributionReady':v['distributionReady'],'AppGroups':0}
    save(output/'helper-build-receipt.json',receipt);save(report/'build.json',receipt)


def finalize(args,pins,report):
    contents=clean_path(args.staging_app)/'Contents';output=contents/'Resources/LiveASR'
    receipt=read_json(output/'helper-build-receipt.json')
    require(receipt['status']=='passed-compile-only' and receipt['inputsBefore']==receipt['inputsAfter'],'Build receipt invalid')
    require(receipt['packagePinsSHA256']==digest(args.pins),'Build recipe differs')
    relative=['Resources/LiveASR/Helpers/media-pcm-pts','Resources/LiveASR/Helpers/online-asr-service','Resources/Tools/ffprobe']
    relative += ['Resources/LiveASR/Helpers/runtime-libs/'+Path(r['relativePath']).name for r in pins['runtimeLibraries']]
    relative += ['Frameworks/'+Path(r['path']).name for r in pins['pcmLibraries']]
    rows=[];env=fixed_environment()
    for rel in sorted(relative):
        p=regular(contents,rel)
        run(['/usr/bin/codesign','--verify','--strict',str(p)],report,'signed-'+str(len(rows)),env,30)
        metadata=abi(p,env,report,'final-abi-'+str(len(rows)))
        rows.append({'path':rel,'bytes':p.stat().st_size,'sha256':digest(p),'ABI':metadata})
    verified=False;evidence=None;verified_first_block=False;verified_range=False
    if args.graceful_evidence:
        e=read_json(args.graceful_evidence)
        pcm=next(r for r in rows if r['path'].endswith('/media-pcm-pts'))
        require(e.get('schema')==1 and e.get('status')=='passed' and e.get('pcmBinarySHA256')==pcm['sha256'] and e.get('pcmSourceSHA256')==pins['pcmSourceSHA256'],'Graceful evidence identity')
        require(e.get('inputsUnchanged') is True and e.get('driverNaturalExitCode')==0 and e.get('forcedCleanup') is False,'Graceful evidence exit')
        require(e.get('defaults')=={'uniqueCases':13,'passed':13,'failed':0},'Original13 default gates missing')
        cases=e.get('gracefulCases',[]);expected={'one-second-whole-chunk','exact-one-second-eof','invalid-limits','resampler-drain-limit','source-mutation','cancel-backpressure'}
        require(len(cases)==len(expected) and {c.get('id') for c in cases}==expected and all(c.get('passed') is True for c in cases),'Graceful case gates')
        evidence={'path':'graceful-limit-evidence.json','bytes':Path(args.graceful_evidence).stat().st_size,'sha256':digest(args.graceful_evidence)}
        shutil.copyfile(args.graceful_evidence,output/evidence['path']);verified=True
        if 'firstBlockHoldCases' in e:
            first=e['firstBlockHoldCases'];expected_first={'short-one-sample-hold','short-one-block-seek','hold-cancel','hold-explicit-limit','hold-control-negative','hold-invalid-flag'}
            require(isinstance(first,list) and len(first)==len(expected_first) and {c.get('id') for c in first}==expected_first and all(c.get('passed') is True for c in first),'First actual block hold case gates')
            verified_first_block=True
        ranges=e.get('rangeCases',[]);expected_range={'aac-fresh-origin-exact-range','pcm-exact-range-controls'}
        require(verified_first_block and isinstance(ranges,list) and len(ranges)==len(expected_range)
                and {c.get('id') for c in ranges}==expected_range and all(c.get('passed') is True for c in ranges),'Exact source range case gates')
        verified_range=True
    value={'schema':1,'profileID':pins['profileID'],'protocol':{'name':'SPCM','version':1,'headerBytes':112},
        'pcmHelperSourceSHA256':pins['pcmSourceSHA256'],'recognizerHelperSourceSHA256':pins['recognizerSourceSHA256'],
        'decoderLibraryABI':'avformat63/avcodec63/avutil61/swresample7','files':rows,
        'features':{'gracefulInputLimit':{'verified':verified,'evidence':evidence},
                    'firstRealBlockHold':{'verified':verified_first_block,'evidence':evidence if verified_first_block else None},
                    'exactSourceRange':{'verified':verified_range,'evidence':evidence if verified_range else None}},
        'limits':{'defaultSeconds':120,'explicitMaximumSeconds':21600,'productMaximumSeconds':120},
        'distributionReady':receipt['distributionReady'],'helperBuildReceiptSHA256':digest(output/'helper-build-receipt.json')}
    save(output/'runtime-manifest.json',value)
    require(all(digest(regular(contents,r['path']))==r['sha256'] for r in rows),'Nested signed bytes changed')
    save(report/'runtime-manifest-receipt.json',{'status':'passed-final-nested-manifest-only','manifestSHA256':digest(output/'runtime-manifest.json'),'files':rows,'supportsGracefulInputLimit':verified,'supportsFirstBlockHold':verified_first_block,'supportsExactSourceRange':verified_range,'AppGroups':0})


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('phase',choices=('bootstrap','build','finalize-runtime'))
    parser.add_argument('--pins',type=Path,required=True)
    parser.add_argument('--expected-pins-sha256',required=True)
    parser.add_argument('--report-directory',type=Path,required=True)
    for flag in ('acquisition-root','ffmpeg-headers-root','target','license-manifest','licenses-root','model-output','project-root','vendor-root','staging-app','work-directory','model-directory','graceful-evidence'):
        parser.add_argument('--'+flag,type=Path)
    parser.add_argument('--distribution',action='store_true')
    args=parser.parse_args();require(digest(args.pins)==args.expected_pins_sha256,'Package pins SHA differs')
    pins=read_json(args.pins);require(pins['schema']==1,'Package schema');report=fresh(args.report_directory)
    save(report/'invocation.json',{'phase':args.phase,'argv':list(os.sys.argv),'pinsSHA256':digest(args.pins),'AppGroups':0})
    try:
        {'bootstrap':bootstrap,'build':build,'finalize-runtime':finalize}[args.phase](args,pins,report)
    except BaseException as error:
        save(report/'failure.json',{'status':'failed','reason':str(error),'AppGroups':0})
        raise


if __name__=='__main__':
    main()
