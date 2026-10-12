#!/usr/bin/env python3
"""Fetch verified upstream libmpv, extract only its arm64 dependency closure.

This is a local GPL prototype bootstrap, not a redistributable dependency audit.
No IINA application is installed or launched. Command Line Tools are required.
"""
from __future__ import annotations

import ctypes
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
VENDOR = ROOT / "Vendor"
LIB = VENDOR / "lib"
HEADERS = ROOT / "Sources" / "CMPV" / "include" / "mpv"
IINA_VERSION = "1.5.0"
MPV_VERSION = "0.41.0"
HEADER_SHA256 = {
    "client.h": "3c073236a09cb456c6e80587d5523c8771c32fb22ca014e0f99cc3d43905b75c",
    "render.h": "192691941602052f00df0587f126246c48785a1cf21de68d22a92ea1908d1c55",
    "render_gl.h": "48662c0ed9872a14dd9e1684105c97f69f94a0414709c254c5d372adc41d2e69",
}
DMG_URL = "https://github.com/iina/iina/releases/download/v1.5.0/IINA.v1.5.0.dmg"
DMG_SHA256 = "8fad50479b10e09645053457cec46bd53d054ced2242cfe68f74586735a20dc7"
DOWNLOADS = VENDOR / "downloads"
LICENSE_SOURCES = {
    "IINA-GPLv3.txt": "https://raw.githubusercontent.com/iina/iina/v1.5.0/LICENSE",
    "mpv-GPLv2.txt": "https://raw.githubusercontent.com/mpv-player/mpv/v0.41.0/LICENSE.GPL",
    "mpv-LGPLv2.1.txt": "https://raw.githubusercontent.com/mpv-player/mpv/v0.41.0/LICENSE.LGPL",
    "FFmpeg-9.0.1-LICENSE.md": "https://raw.githubusercontent.com/FFmpeg/FFmpeg/n9.0.1/LICENSE.md",
    "FFmpeg-9.0.1-GPLv2.txt": "https://raw.githubusercontent.com/FFmpeg/FFmpeg/n9.0.1/COPYING.GPLv2",
    "FFmpeg-9.0.1-GPLv3.txt": "https://raw.githubusercontent.com/FFmpeg/FFmpeg/n9.0.1/COPYING.GPLv3",
    "FFmpeg-9.0.1-LGPLv2.1.txt": "https://raw.githubusercontent.com/FFmpeg/FFmpeg/n9.0.1/COPYING.LGPLv2.1",
    "FFmpeg-9.0.1-LGPLv3.txt": "https://raw.githubusercontent.com/FFmpeg/FFmpeg/n9.0.1/COPYING.LGPLv3",
    "rubberband-COPYING.txt": "https://raw.githubusercontent.com/breakfastquay/rubberband/default/COPYING",
    "libass-COPYING.txt": "https://raw.githubusercontent.com/libass/libass/master/COPYING",
    "libplacebo-LICENSE.txt": "https://raw.githubusercontent.com/haasn/libplacebo/master/LICENSE",
}


def run(*args: object) -> str:
    return subprocess.check_output([str(a) for a in args], text=True, stderr=subprocess.STDOUT)


def digest(path: Path) -> str:
    result = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def download(url: str, path: Path, expected: str | None = None) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists() and (expected is None or digest(path) == expected):
        return
    temporary = path.with_name(path.name + ".part")
    # A complete .part from an interrupted bootstrap can be adopted safely.
    if expected and temporary.exists() and digest(temporary) == expected:
        temporary.replace(path)
        return
    print(f"Downloading {url}", flush=True)
    subprocess.run([
        "curl", "--fail", "--location", "--retry", "3", "--connect-timeout", "20",
        "--max-time", "900", "--silent", "--show-error", "--output", str(temporary), url,
    ], check=True)
    if expected and digest(temporary) != expected:
        raise RuntimeError(f"SHA256 mismatch: {temporary}; refusing to use the download")
    temporary.replace(path)


def is_system(reference: str) -> bool:
    return reference.startswith(("/usr/lib/", "/System/Library/", "/Library/Apple/System/"))


def install_id(path: Path) -> str:
    lines = run("otool", "-arch", "arm64", "-D", path).splitlines()
    return lines[-1].strip()


def dependencies(path: Path) -> list[str]:
    own_id = install_id(path)
    result = re.findall(r"^\s+(.+?)\s+\(compatibility version", run("otool", "-arch", "arm64", "-L", path), re.M)
    return [entry for entry in result if entry != own_id]


def metadata(path: Path) -> dict:
    version = re.search(r"current version ([0-9.]+)", run("otool", "-arch", "arm64", "-L", path))
    build = run("otool", "-arch", "arm64", "-l", path)
    min_os = re.search(r"\bminos ([0-9.]+)", build)
    return {
        "name": path.name,
        "sha256": digest(path),
        "architecture": run("lipo", "-archs", path).strip(),
        "dylib_current_version": version.group(1) if version else None,
        "minimum_macos": min_os.group(1) if min_os else None,
        "install_id": install_id(path),
        "dependencies": dependencies(path),
    }


def extract(dmg: Path) -> list[dict]:
    with tempfile.TemporaryDirectory(prefix="siliconplayer-mpv-") as temp:
        mount = Path(temp) / "mount"
        mount.mkdir()
        print("Mounting verified IINA image read-only (no installation)", flush=True)
        run("hdiutil", "attach", dmg, "-readonly", "-nobrowse", "-mountpoint", mount)
        try:
            frameworks = mount / "IINA.app" / "Contents" / "Frameworks"
            candidates = list(frameworks.glob("libmpv.*.dylib"))
            if len(candidates) != 1:
                raise RuntimeError(f"Expected one upstream libmpv version; found {candidates}")
            pending = [candidates[0]]
            closure: dict[str, Path] = {}
            while pending:
                source = pending.pop()
                if source.name in closure:
                    continue
                closure[source.name] = source
                for dependency in dependencies(source):
                    if is_system(dependency):
                        continue
                    child = frameworks / Path(dependency).name
                    if not child.is_file() or child.suffix != ".dylib":
                        raise RuntimeError(f"Unresolved non-system dependency: {source.name}: {dependency}")
                    pending.append(child)
            LIB.mkdir(parents=True, exist_ok=True)
            # Stage locally so a failed extraction never leaves mixed dependency sets.
            staging = Path(temp) / "lib"
            staging.mkdir()
            records = []
            for name, source in sorted(closure.items()):
                target = staging / name
                upstream_hash = digest(source)
                arches = run("lipo", "-archs", source).split()
                if "arm64" not in arches:
                    raise RuntimeError(f"Upstream dependency has no arm64 slice: {name}")
                if arches == ["arm64"]:
                    shutil.copyfile(source, target)
                else:
                    run("lipo", source, "-thin", "arm64", "-output", target)
                target.chmod(0o755)
                for dependency in dependencies(target):
                    if not is_system(dependency):
                        run("install_name_tool", "-change", dependency, "@loader_path/" + Path(dependency).name, target)
                run("install_name_tool", "-id", "@rpath/" + name, target)
                run("codesign", "--force", "--sign", "-", "--timestamp=none", target)
                record = metadata(target)
                record.update({
                    "upstream_sha256": upstream_hash,
                    "upstream_architectures": arches,
                    "source": "IINA.app/Contents/Frameworks/" + name,
                    "modifications": ["arm64 slice only", "non-system dependencies use @loader_path", "ad hoc code signature"],
                })
                records.append(record)
            for old in LIB.glob("*.dylib"):
                # exFAT creates AppleDouble sidecars and may remove them with
                # their data fork; never treat ._ files as libraries.
                if not old.name.startswith("._"):
                    old.unlink(missing_ok=True)
            for source in staging.glob("*.dylib"):
                shutil.copyfile(source, LIB / source.name)
            # exFAT does not support symlinks. Linker alias is a regular copy.
            shutil.copyfile(LIB / candidates[0].name, LIB / "libmpv.dylib")
            print(f"Extracted {len(records)} arm64 dylibs; excluded IINA UI and Sparkle", flush=True)
            return records
        finally:
            run("hdiutil", "detach", mount)


def probe_runtime() -> dict:
    mpv = ctypes.CDLL(str(LIB / "libmpv.dylib"))
    mpv.mpv_client_api_version.restype = ctypes.c_ulong
    api = mpv.mpv_client_api_version()
    mpv.mpv_create.restype = ctypes.c_void_p
    mpv.mpv_set_option_string.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p]
    mpv.mpv_initialize.argtypes = [ctypes.c_void_p]
    mpv.mpv_get_property_string.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
    mpv.mpv_get_property_string.restype = ctypes.c_void_p
    mpv.mpv_free.argtypes = [ctypes.c_void_p]
    mpv.mpv_terminate_destroy.argtypes = [ctypes.c_void_p]
    handle = mpv.mpv_create()
    if not handle:
        raise RuntimeError("mpv_create failed")
    values = {}
    try:
        for option, value in [(b"config", b"no"), (b"vo", b"null"), (b"ao", b"null")]:
            if mpv.mpv_set_option_string(handle, option, value) < 0:
                raise RuntimeError(f"mpv rejected bootstrap option {option!r}")
        if mpv.mpv_initialize(handle) < 0:
            raise RuntimeError("mpv_initialize failed")
        for property_name in ["mpv-version", "ffmpeg-version", "mpv-configuration"]:
            pointer = mpv.mpv_get_property_string(handle, property_name.encode())
            if pointer:
                values[property_name] = ctypes.string_at(pointer).decode("utf-8", errors="replace")
                mpv.mpv_free(pointer)
    finally:
        mpv.mpv_terminate_destroy(handle)
    values["client_api"] = f"{api >> 16}.{api & 65535}"
    if values.get("mpv-version") != "mpv v" + MPV_VERSION or (api >> 16, api & 65535) != (2, 5):
        raise RuntimeError(f"Unexpected libmpv runtime: {values}")
    avutil_path = next(path for path in LIB.glob("libavutil.*.dylib") if not path.name.startswith("._"))
    avutil = ctypes.CDLL(str(avutil_path))
    avutil.avutil_license.restype = ctypes.c_char_p
    avutil.avutil_configuration.restype = ctypes.c_char_p
    values["ffmpeg-license"] = avutil.avutil_license().decode("utf-8")
    values["ffmpeg-configuration"] = avutil.avutil_configuration().decode("utf-8")
    print(f"Runtime verified: {values['mpv-version']}, API {values['client_api']}", flush=True)
    return values


def verify_vendor() -> None:
    manifest = json.loads((VENDOR / "manifest.json").read_text(encoding="utf-8"))
    if manifest["source"]["sha256"] != DMG_SHA256 or manifest["architecture"] != "arm64":
        raise RuntimeError("Vendor provenance does not match this pinned bootstrap")
    for record in manifest["libraries"]:
        path = LIB / record["name"]
        if digest(path) != record["sha256"] or run("lipo", "-archs", path).strip() != "arm64":
            raise RuntimeError(f"Vendor library hash or architecture mismatch: {path.name}")
        for dependency in dependencies(path):
            if not is_system(dependency) and (
                not dependency.startswith("@loader_path/") or not (LIB / Path(dependency).name).is_file()
            ):
                raise RuntimeError(f"Unresolved bundled dependency: {path.name}: {dependency}")
    for name, expected in HEADER_SHA256.items():
        if digest(HEADERS / name) != expected:
            raise RuntimeError(f"Official mpv header hash mismatch: {name}")
    if digest(LIB / "libmpv.dylib") != manifest["linker_alias"]["sha256"]:
        raise RuntimeError("libmpv linker alias hash mismatch")
    print(f"Verified {len(manifest['libraries'])} arm64 libraries and official headers", flush=True)


def main() -> None:
    if sys.platform != "darwin" or run("uname", "-m").strip() != "arm64":
        raise RuntimeError("Bootstrap requires an Apple Silicon Mac")
    if sys.argv[1:] == ["--verify"]:
        verify_vendor()
        return
    if sys.argv[1:]:
        raise RuntimeError("Usage: bootstrap_mpv.py [--verify]")
    VENDOR.mkdir(parents=True, exist_ok=True)
    dmg = DOWNLOADS / "IINA.v1.5.0.dmg"
    download(DMG_URL, dmg, DMG_SHA256)
    records = extract(dmg)
    HEADERS.mkdir(parents=True, exist_ok=True)
    headers = []
    for name in ("client.h", "render.h", "render_gl.h"):
        url = f"https://raw.githubusercontent.com/mpv-player/mpv/v{MPV_VERSION}/include/mpv/{name}"
        target = HEADERS / name
        download(url, target, HEADER_SHA256[name])
        headers.append({"path": str(target.relative_to(ROOT)), "source": url, "sha256": digest(target), "version": MPV_VERSION})
    license_records = []
    for name, url in LICENSE_SOURCES.items():
        target = VENDOR / "licenses" / name
        download(url, target)
        license_records.append({"path": str(target.relative_to(ROOT)), "source": url, "sha256": digest(target)})
    scope = (
        "LOCAL GPL PROTOTYPE ONLY - NOT RELEASE CLEARED\n\n"
        "The linked playback stack includes GPL components such as mpv/FFmpeg/rubberband.\n"
        "ISC permissions in the API headers do not change the linked runtime's licenses.\n"
        "This bootstrap extracts only the dependency closure of IINA's official libmpv.\n"
        "IINA UI, assets, Sparkle, and IINA executable are not copied or launched.\n"
        "The original upstream license texts saved here are an initial notice set, not\n"
        "a complete per-library license/copyright audit or corresponding-source archive.\n"
        "Before any distribution, inventory every bundled library; preserve all notices;\n"
        "provide complete corresponding source and build/patch scripts as required;\n"
        "and confirm GPL compatibility for the whole application. Closed-source\n"
        "compatibility is not claimed. This bundle is not approved for App Store release.\n"
    )
    (VENDOR / "licenses" / "SCOPE.txt").write_text(scope, encoding="utf-8")
    runtime = probe_runtime()
    manifest = {
        "schema": 1,
        "generated_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "source": {"project": "IINA", "version": IINA_VERSION, "url": DMG_URL, "sha256": DMG_SHA256,
                   "digest_source": "https://api.github.com/repos/iina/iina/releases/tags/v1.5.0"},
        "architecture": "arm64",
        "mpv_version": MPV_VERSION,
        "runtime": runtime,
        "linker_alias": {"name": "libmpv.dylib", "alias_of": "libmpv.2.dylib", "sha256": digest(LIB / "libmpv.dylib")},
        "libraries": records,
        "headers": headers,
        "licenses": license_records,
        "release_cleared": False,
        "license_scope": "Local GPL prototype. Full dependency notice and corresponding-source audit required before redistribution.",
    }
    (VENDOR / "manifest.json").write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print("Vendor/manifest.json saved; the local GPL runtime is ready", flush=True)


if __name__ == "__main__":
    main()
