#!/usr/bin/env python3
"""Package an unchanged tested arm64 app with public legal resources on macOS.

All paths are explicit arguments. Only the existing work/payload app, new
work/evidence, work/roundtrip and work ZIP are written. The sealed baseline is
read-only. Commands use a caller-supplied reviewed Darwin owned-process runner;
its ABI must already have been validated for the current host by the caller.
No app, ffmpeg, GPU, network, dependency build or fresh functional tests run.
"""
import argparse, datetime, hashlib, importlib.util, json, os, platform
from pathlib import Path
import shutil, stat, struct, sys, zipfile
sys.dont_write_bytecode = True
IJG = 'This software is based in part on the work of the Independent JPEG Group.'
FTL = 'Portions of this software are copyright © 2026 The FreeType Project (https://freetype.org). All rights reserved.'
LEGAL = ['LICENSE', 'NOTICE.md', 'THIRD_PARTY.md', 'SOURCE_LINKS.txt', 'INSTALL.md']


def require(value, reason):
    if not value:
        raise RuntimeError(reason)


def regular(path):
    path = Path(path)
    require(path.is_absolute() and path == Path(os.path.normpath(str(path))), 'Canonical absolute path required')
    for part in [*reversed(path.parents), path]:
        require(not stat.S_ISLNK(part.lstat().st_mode), 'Symlink input rejected: ' + str(path))
    require(stat.S_ISREG(path.lstat().st_mode), 'Regular input required: ' + str(path))
    return path


def sha(path):
    path = regular(path)
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest() if hasattr(hashlib, 'file_digest') else hashlib.sha256(stream.read()).hexdigest()


def read(path):
    def pairs(rows):
        result = {}
        for key, value in rows:
            require(key not in result, 'Duplicate JSON key')
            result[key] = value
        return result
    return json.loads(regular(path).read_bytes(), object_pairs_hook=pairs,
        parse_constant=lambda value: (_ for _ in ()).throw(RuntimeError('Nonfinite JSON')))


def save(path, value):
    with Path(path).open('x', encoding='utf-8') as stream:
        json.dump(value, stream, ensure_ascii=False, indent=2, allow_nan=False)
        stream.write('\n'); stream.flush(); os.fsync(stream.fileno())


def inventory(root):
    require(root.is_dir() and not root.is_symlink(), 'Materialized directory required')
    result = {}
    for path in sorted(root.rglob('*')):
        relative = path.relative_to(root)
        if any(part.startswith('._') for part in relative.parts):
            continue
        information = path.lstat()
        require(not stat.S_ISLNK(information.st_mode), 'Directory symlink rejected')
        if stat.S_ISREG(information.st_mode):
            result[str(relative)] = {'bytes': information.st_size, 'sha256': sha(path), 'mode': stat.S_IMODE(information.st_mode)}
        else:
            require(stat.S_ISDIR(information.st_mode), 'Special node rejected')
    return result


def copy_regular(source, destination):
    source = regular(source)
    destination.parent.mkdir(parents=True, exist_ok=True)
    require(not destination.is_symlink(), 'Destination symlink rejected')
    with source.open('rb') as src, destination.open('wb') as dst:
        shutil.copyfileobj(src, dst)
    destination.chmod(0o644)


def sections(path):
    raw = regular(path).read_bytes()
    require(len(raw) >= 32 and raw[:4] == b'\xcf\xfa\xed\xfe', 'Thin little-endian Mach-O 64 required')
    _, cpu, subtype, filetype, count, size, flags, reserved = struct.unpack_from('<8I', raw, 0)
    require(cpu == 0x0100000c and count <= 1024 and 32 + size <= len(raw), 'arm64 Mach-O required')
    offset = 32; result = []
    for _ in range(count):
        command, command_size = struct.unpack_from('<II', raw, offset)
        require(command_size >= 8 and offset + command_size <= 32 + size, 'Load command bound')
        if command == 0x19:
            require(command_size >= 72, 'Segment bound')
            nsections = struct.unpack_from('<I', raw, offset + 64)[0]
            require(72 + nsections * 80 <= command_size, 'Section table bound')
            for index in range(nsections):
                base = offset + 72 + index * 80
                name = raw[base:base+16].split(b'\0', 1)[0].decode('ascii')
                segment = raw[base+16:base+32].split(b'\0', 1)[0].decode('ascii')
                length = struct.unpack_from('<Q', raw, base + 40)[0]
                start = struct.unpack_from('<I', raw, base + 48)[0]
                section_flags = struct.unpack_from('<I', raw, base + 64)[0]
                # S_ZEROFILL, S_GB_ZEROFILL, S_THREAD_LOCAL_ZEROFILL have no file data.
                row = {'segment': segment, 'section': name, 'bytes': length,
                    'offset': start, 'flags': section_flags}
                if section_flags & 0xff not in [1, 12, 18]:
                    require(start + length <= len(raw), 'Section outside file')
                    row['sha256'] = hashlib.sha256(raw[start:start+length]).hexdigest()
                result.append(row)
        offset += command_size
    require(offset == 32 + size, 'Load command total differs')
    return result


def natural(rows):
    return bool(rows) and all(row.get('spawned') is True and type(row.get('exit')) is int and row['exit'] == 0
        and row.get('forcedCleanup') is False and row.get('timedOut') is False and row.get('signals') == []
        and row.get('leaderHeldUnreapedUntilWholeGroupNoLive') is True and row.get('leaderReaped') is True
        and row.get('ownedGroupAbsent') is True and row.get('remainingGroupMembers') == [] for row in rows)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['work', 'baseline-app', 'baseline-inventory', 'main-sections', 'notices', 'runtime-map',
                 'license-selection', 'license-selection-md', 'legal', 'owner-driver', 'abi-receipt']:
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--owner-driver-sha256', required=True)
    parser.add_argument('--abi-receipt-sha256', required=True)
    parser.add_argument('--zip-name', default='SiliconPlayer-0.6.0-core-arm64-public.zip')
    args = parser.parse_args()
    require(platform.system() == 'Darwin' and platform.machine() == 'arm64' and __debug__, 'Native arm64 macOS required')
    for name, value in vars(args).items():
        if isinstance(value, Path):
            require(value.is_absolute() and value == Path(os.path.normpath(str(value))), 'All paths must be canonical absolute')
    work = args.work; payload = work / 'payload'; app = payload / 'SiliconPlayer.app'; evidence = work / 'evidence'
    require(payload.is_dir() and not payload.is_symlink() and args.baseline_app != app
        and not args.baseline_app.is_relative_to(work) and not evidence.exists(), 'Exclusive existing work payload required')
    require(args.zip_name == Path(args.zip_name).name and args.zip_name.endswith('.zip'), 'Plain ZIP filename required')
    archive = work / args.zip_name; roundtrip = work / 'roundtrip'
    require(not archive.exists() and not roundtrip.exists(), 'New ZIP and roundtrip paths required')
    require(sha(args.owner_driver) == args.owner_driver_sha256 and sha(args.abi_receipt) == args.abi_receipt_sha256, 'Owner and caller-validated ABI pins differ')
    baseline = inventory(args.baseline_app); require(baseline == read(args.baseline_inventory) and len(baseline) == 75, 'Sealed 75-file baseline differs')
    original_sections = sections(args.baseline_app / 'Contents/MacOS/SiliconPlayer')
    require(original_sections == read(args.main_sections) and len(original_sections) == 46, 'Sealed 46 main sections differ')
    runtime = read(args.runtime_map); rows = runtime['libraries']; require(runtime['runtimeLibraryCount'] == len(rows) == 44, '44 exact runtime mappings required')
    for row in rows:
        require(baseline['Contents/Frameworks/' + row['name']]['sha256'] == row['binarySHA256'], 'Runtime source map differs')
    notice_manifest = read(args.notices / 'manifest.json')
    notice_files = inventory(args.notices)
    require(len(notice_files) == 125 and sum(row['bytes'] for row in notice_files.values()) == 774150, 'Final 125-file notice set differs')
    require(notice_manifest['fileCount'] == len(notice_manifest['files']) == 124
        and notice_manifest['bytes'] == 753749, 'Notice manifest size differs')
    for row in notice_manifest['files']:
        require(notice_files[row['path']]['bytes'] == row['bytes'] and notice_files[row['path']]['sha256'] == row['sha256'], 'Notice source differs')
    legal = {}
    for name in LEGAL:
        raw = regular(args.legal / name).read_bytes()
        if name in ['NOTICE.md', 'THIRD_PARTY.md']:
            text = raw.decode('utf-8')
            for attribution in [IJG, FTL]:
                if attribution not in text:
                    text = text.rstrip() + '\n\n' + attribution + '\n'
            text = text.replace('(Docs/DEPENDENCIES.md)', '(https://github.com/RGB-hengzhi/SiliconPlayer/blob/main/Docs/DEPENDENCIES.md)')
            raw = text.encode('utf-8')
        legal[name] = raw
    require(b'SiliconPlayer-0.6.0-core-dependency-source.zip' in legal['SOURCE_LINKS.txt'], 'Final singular dependency asset name required')
    evidence.mkdir()
    held_paths = [args.baseline_inventory, args.main_sections, args.runtime_map, args.license_selection,
        args.license_selection_md, args.owner_driver, args.abi_receipt, args.legal / 'SCOPE.txt', *[args.legal / name for name in LEGAL]]
    held = {str(path): sha(path) for path in held_paths}
    save(evidence / 'baseline-app.json', baseline); save(evidence / 'notice-source.json', notice_files)
    save(evidence / 'input-pins.json', held); save(evidence / 'main-code-sections-before.json', original_sections)
    resource = app / 'Contents/Resources'; license_root = resource / 'Licenses'
    for name, raw in legal.items():
        (payload / name).write_bytes(raw); (payload / name).chmod(0o644)
        if name != 'INSTALL.md':
            (license_root / name).write_bytes(raw); (license_root / name).chmod(0o644)
    copy_regular(args.legal / 'SCOPE.txt', license_root / 'SCOPE.txt')
    copy_regular(args.legal / 'LICENSE', resource / 'SiliconPlayer-LICENSE.txt')
    # Preserve all existing third-party texts; add the final small collection under a new directory.
    notice_destination = license_root / 'Dependencies'
    require(not notice_destination.exists(), 'Notice destination must be new')
    for name in notice_files:
        copy_regular(args.notices / name, notice_destination / name)
    for source, name in [(args.runtime_map, 'runtime-to-source.json'), (args.license_selection, 'license-selection.json'),
                         (args.license_selection_md, 'LICENSE_SELECTION.md')]:
        copy_regular(source, license_root / name); copy_regular(source, payload / name)
    instructions = ('# Public application legal resources\n\n'
        'The original application is GPL-3.0-or-later. LICENSE and SiliconPlayer-LICENSE.txt contain the complete GNU GPLv3 text. '
        'NOTICE.md preserves original attribution, THIRD_PARTY.md summarizes component boundaries, and SOURCE_LINKS.txt points to corresponding-source assets.\n\n'
        'Dependencies/ contains the final 125-file original notice collection; its manifest lists 124 source texts plus the manifest itself. '
        'runtime-to-source.json binds all 44 runtime libraries to exact source archives; license-selection.json and LICENSE_SELECTION.md record selected license alternatives. '
        'Existing third-party notices remain unchanged outside SCOPE.txt. The public derivative changes legal resources and the outer ad-hoc signature only. '
        'Baseline functional tests are historical evidence for identical code sections, not new tests of this packaging derivative.\n')
    (license_root / 'PUBLIC_RESOURCES.md').write_text(instructions, encoding='utf-8'); (license_root / 'PUBLIC_RESOURCES.md').chmod(0o644)
    # Normalize only the owned public payload; preserve executable bits from the baseline app.
    for path in payload.rglob('*'):
        require(not path.is_symlink(), 'Owned payload symlink rejected')
        if path.is_dir(): path.chmod(0o755)
        elif path.is_file(): path.chmod(0o755 if os.access(path, os.X_OK) else 0o644)
    require(all(inventory(app)[name]['sha256'] == row['sha256'] for name, row in baseline.items()
        if name.startswith('Contents/Frameworks/') or name in ['Contents/Resources/Tools/ffmpeg', 'Contents/Resources/Tools/ffprobe']), 'Nested runtime bytes changed before sign')
    environment = {key: value for key, value in os.environ.items() if not key.startswith(('DYLD_', 'SILICONPLAYER_', 'PYTHON'))}
    spec = importlib.util.spec_from_file_location('public_packaging_owner', regular(args.owner_driver)); module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    owner = module.Owner(evidence, environment)
    summary = {'schema': 1, 'status': 'failed-preserved', 'actualNewFunctionalTests': 0,
        'fresh170Claimed': False, 'ownerABIContext': 'Caller-validated current host ABI receipt; this script checks its exact bytes, does not rerun that probe.',
        'baselineApp': str(args.baseline_app), 'publicApp': str(app), 'zip': str(archive), 'nestedLibrariesResigned': False,
        'callerABIReceiptSHA256': args.abi_receipt_sha256, 'packagingDriverSHA256': sha(Path(__file__).absolute())}
    try:
        owner.run('outer-adhoc-sign', ['/usr/bin/codesign', '--force', '--sign', '-', str(app)], timeout=120, cwd=work)
        owner.run('public-deep-strict-signature', ['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)], timeout=120, cwd=work)
        actual = inventory(app); current_sections = sections(app / 'Contents/MacOS/SiliconPlayer')
        require(current_sections == original_sections, 'Main code sections changed after outer sign')
        unchanged_runtime = [name for name in baseline if name.startswith('Contents/Frameworks/') or name in ['Contents/Resources/Tools/ffmpeg', 'Contents/Resources/Tools/ffprobe']]
        require(len(unchanged_runtime) == 46 and all(actual[name]['sha256'] == baseline[name]['sha256'] for name in unchanged_runtime), 'Nested runtime bytes changed after sign')
        images = [app / 'Contents/MacOS/SiliconPlayer', *[app / name for name in unchanged_runtime]]
        for index, image in enumerate(images):
            sections(image)  # actual header/section bounds and arm64 check
            owner.run('arm64-image-' + str(index).zfill(2), ['/usr/bin/lipo', '-archs', str(image)], timeout=30, cwd=work)
            require((evidence / 'stages' / ('arm64-image-' + str(index).zfill(2)) / 'stdout.txt').read_text().strip() == 'arm64', 'Non-arm64 image')
        save(evidence / 'main-code-sections-after.json', current_sections); save(evidence / 'public-app-inventory.json', actual)
        payload_inventory = inventory(payload); save(evidence / 'payload-inventory.json', payload_inventory)
        owner.run('public-zip-create', ['/usr/bin/ditto', '-c', '-k', '--norsrc', '--noextattr', str(payload), str(archive)], timeout=180, cwd=work)
        roundtrip.mkdir()
        owner.run('public-zip-unpack', ['/usr/bin/ditto', '-x', '-k', '--norsrc', '--noextattr', str(archive), str(roundtrip)], timeout=120, cwd=work)
        require(inventory(roundtrip) == payload_inventory, 'APFS ZIP roundtrip file bytes/modes differ')
        save(evidence / 'roundtrip-inventory.json', inventory(roundtrip))
        owner.run('roundtrip-deep-strict-signature', ['/usr/bin/codesign', '--verify', '--deep', '--strict', str(roundtrip / 'SiliconPlayer.app')], timeout=120, cwd=work)
        with zipfile.ZipFile(archive) as stream:
            zipped = {}
            for row in stream.infolist():
                if row.is_dir(): continue
                require(not any(part.startswith(('._', '__MACOSX')) for part in Path(row.filename).parts), 'AppleDouble archive entry')
                require(row.filename not in zipped, 'Duplicate ZIP entry')
                zipped[row.filename] = {'bytes': row.file_size, 'sha256': hashlib.sha256(stream.read(row)).hexdigest(), 'mode': stat.S_IMODE(row.external_attr >> 16)}
            require(zipped == payload_inventory, 'ZIP entries differ')
        changes = {'added': sorted(set(actual) - set(baseline)), 'removed': sorted(set(baseline) - set(actual)),
            'changedBytes': sorted(name for name in set(actual) & set(baseline) if actual[name]['sha256'] != baseline[name]['sha256']),
            'changedModes': sorted(name for name in set(actual) & set(baseline) if actual[name]['mode'] != baseline[name]['mode'])}
        require(changes['removed'] == [], 'Baseline app file removed')
        allowed = {'Contents/MacOS/SiliconPlayer', 'Contents/_CodeSignature/CodeResources', 'Contents/Resources/Licenses/SCOPE.txt'}
        require(set(changes['changedBytes']) <= allowed and all(name.startswith('Contents/Resources/') for name in changes['added']), 'Unexpected functional-byte change')
        require(inventory(args.baseline_app) == baseline and all(sha(Path(path)) == value for path, value in held.items()), 'Read-only source inputs changed')
        summary.update(status='public-legal-signature-packaging-passed-runtime-smoke-pending',
            baselineMainSHA256=baseline['Contents/MacOS/SiliconPlayer']['sha256'], publicMainSHA256=actual['Contents/MacOS/SiliconPlayer']['sha256'],
            publicAppFiles=len(actual), publicAppBytes=sum(row['bytes'] for row in actual.values()),
            payloadFiles=len(payload_inventory), payloadBytes=sum(row['bytes'] for row in payload_inventory.values()),
            mainCodeSections46Identical=True, all47MachOArm64=True, all44LibrariesAnd2ToolsByteIdentical=True,
            original75FileBaselineUnchanged=True, legalSourceInputsUnchanged=True, exactAPFSZipRoundtripIncludingModes=True,
            changes=changes, dependencyNoticeFiles=125, dependencyNoticeBytes=774150,
            zipBytes=archive.stat().st_size, zipSHA256=sha(archive), finishedUTC=datetime.datetime.now(datetime.timezone.utc).isoformat())
    except BaseException as error:
        summary.update(errorType=type(error).__name__, error=str(error))
    finally:
        summary.update(ownerStages=owner.rows, ownedCleanup=owner.cleanup())
        if not natural(owner.rows) or summary['ownedCleanup']['cleanupRows'] or summary['ownedCleanup']['unreapedOwnedPIDs']:
            summary['status'] = 'failed-preserved'
        save(evidence / 'summary.json', summary)
    print(json.dumps({key: summary.get(key) for key in ['status', 'publicMainSHA256', 'zipBytes', 'zipSHA256', 'error']}, ensure_ascii=False))
    return 0 if summary['status'] == 'public-legal-signature-packaging-passed-runtime-smoke-pending' else 1


if __name__ == '__main__':
    raise SystemExit(main())
