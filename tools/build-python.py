#!/usr/bin/env python3
"""Builds the Python runtime that the app carries.

The app runs yt-dlp inside itself: CPython (BeeWare's Python-Apple-support
build for iOS), the standard library, yt-dlp, its EJS challenge scripts and our
JavaScriptCore provider.  This script downloads the pieces and lays them out the
way App/PythonBridge.swift expects:

    vendor/Python.framework/            linked and embedded (device slice)
    PythonRuntime/lib/python3.14/       PYTHONHOME
    PythonRuntime/lib/python3.14/lib-dynload/
    PythonRuntime/lib/python3.14/site-packages/
        yt_dlp/  yt_dlp_ejs/  certifi/  yt_dlp_plugins/  ytm_bridge.py  ytm_js.py

Run it before `xcodegen generate` (CI does):

    python3 tools/build-python.py

Everything is pinned; change the versions at the top to update.
"""

import argparse
import hashlib
import json
import os
import shutil
import tarfile
import urllib.request
import zipfile

# --- pinned versions -------------------------------------------------------

PYTHON_TAG = '3.14-b14'          # Python-Apple-support release
PYTHON_VERSION = '3.14'          # must match PythonRuntime.version in Swift
PYTHON_SHA256 = None             # set to pin the support package download

YT_DLP = '2026.10.26'
YT_DLP_EJS = '0.8.0'
CERTIFI = '2026.10.23'

SUPPORT_URL = (
    'https://github.com/beeware/Python-Apple-support/releases/download/'
    f'{PYTHON_TAG}/Python-3.14-iOS-support.{PYTHON_TAG.split("-")[-1]}.tar.gz'
)

# Parts of the standard library the app never needs (the single biggest one is
# `test`, about 33 MB of the 47 MB).
STDLIB_SKIP = {'test', 'tkinter', 'idlelib', 'turtledemo', 'ensurepip', 'venv', 'pydoc_data'}


def log(message):
    print('[python] ' + message, flush=True)


def download(url, path):
    if os.path.exists(path):
        log('cached ' + os.path.basename(path))
        return path
    log('downloading ' + url)
    os.makedirs(os.path.dirname(path) or '.', exist_ok=True)
    with urllib.request.urlopen(url, timeout=120) as response, open(path, 'wb') as fh:
        shutil.copyfileobj(response, fh)
    return path


def pypi_file(name, version, suffixes):
    """The first file of a PyPI release whose name ends with one of `suffixes`."""
    url = f'https://pypi.org/pypi/{name}/{version}/json'
    with urllib.request.urlopen(url, timeout=60) as response:
        data = json.load(response)
    for entry in data['urls']:
        for suffix in suffixes:
            if entry['filename'].endswith(suffix):
                return entry['url'], entry['filename']
    raise SystemExit(f'no {suffixes} file for {name} {version}')


def unpack(archive, target):
    os.makedirs(target, exist_ok=True)
    if archive.endswith('.zip') or archive.endswith('.whl'):
        with zipfile.ZipFile(archive) as zf:
            zf.extractall(target)
    else:
        with tarfile.open(archive) as tf:
            tf.extractall(target)
    return target


def copy_tree(src, dst, skip=()):
    if os.path.exists(dst):
        shutil.rmtree(dst)
    os.makedirs(dst)
    for name in os.listdir(src):
        if name in skip or name == '__pycache__':
            continue
        source = os.path.join(src, name)
        target = os.path.join(dst, name)
        if os.path.isdir(source):
            shutil.copytree(source, target)
        else:
            shutil.copy2(source, target)


def tree_size(path):
    total = 0
    for root, _, names in os.walk(path):
        for name in names:
            try:
                total += os.path.getsize(os.path.join(root, name))
            except OSError:
                pass
    return total


def build(out_root, cache):
    repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    runtime = os.path.join(out_root, 'PythonRuntime')
    vendor = os.path.join(out_root, 'vendor')
    stdlib = os.path.join(runtime, 'lib', 'python' + PYTHON_VERSION)
    site = os.path.join(stdlib, 'site-packages')

    os.makedirs(cache, exist_ok=True)

    # 1. CPython for iOS ---------------------------------------------------
    support_dir = os.path.join(cache, 'support-' + PYTHON_TAG)
    if not os.path.isdir(support_dir):
        archive = download(SUPPORT_URL, os.path.join(cache, 'python-ios.tar.gz'))
        if PYTHON_SHA256:
            digest = hashlib.sha256(open(archive, 'rb').read()).hexdigest()
            if digest != PYTHON_SHA256:
                raise SystemExit(f'Python support package hash mismatch: {digest}')
        unpack(archive, support_dir)

    xcframework = os.path.join(support_dir, 'Python.xcframework')
    device = os.path.join(xcframework, 'ios-arm64')
    if not os.path.isdir(device):
        raise SystemExit('the support package has no ios-arm64 slice')

    log('standard library')
    os.makedirs(stdlib, exist_ok=True)
    copy_tree(os.path.join(xcframework, 'lib', 'python' + PYTHON_VERSION), stdlib,
              skip=STDLIB_SKIP | {'site-packages', 'lib-dynload'})

    log('binary modules')
    modules = os.path.join(device, 'lib-arm64', 'python' + PYTHON_VERSION)
    copy_tree(os.path.join(modules, 'lib-dynload'), os.path.join(stdlib, 'lib-dynload'))
    for name in os.listdir(modules):
        if name.startswith('_sysconfigdata') or name.startswith('_sysconfig_vars'):
            shutil.copy2(os.path.join(modules, name), os.path.join(stdlib, name))

    # 2. yt-dlp and its challenge solver ----------------------------------
    log(f'yt-dlp {YT_DLP}')
    url, filename = pypi_file('yt-dlp', YT_DLP, ['.tar.gz'])
    src = unpack(download(url, os.path.join(cache, filename)), os.path.join(cache, 'yt-dlp-src'))
    package_root = None
    for name in os.listdir(src):
        candidate = os.path.join(src, name)
        if os.path.isdir(os.path.join(candidate, 'yt_dlp')):
            package_root = candidate
            break
    if not package_root:
        raise SystemExit('yt_dlp package not found in the sdist')
    os.makedirs(site, exist_ok=True)
    copy_tree(os.path.join(package_root, 'yt_dlp'), os.path.join(site, 'yt_dlp'))

    log(f'yt-dlp-ejs {YT_DLP_EJS}')
    url, filename = pypi_file('yt-dlp-ejs', YT_DLP_EJS, ['.whl'])
    wheel = unpack(download(url, os.path.join(cache, filename)), os.path.join(cache, 'ejs-wheel'))
    copy_tree(os.path.join(wheel, 'yt_dlp_ejs'), os.path.join(site, 'yt_dlp_ejs'))

    log(f'certifi {CERTIFI}')
    url, filename = pypi_file('certifi', CERTIFI, ['.whl'])
    wheel = unpack(download(url, os.path.join(cache, filename)), os.path.join(cache, 'certifi-wheel'))
    copy_tree(os.path.join(wheel, 'certifi'), os.path.join(site, 'certifi'))

    # 3. Our own Python ----------------------------------------------------
    log('app modules')
    copy_tree(os.path.join(repo, 'Py', 'yt_dlp_plugins'), os.path.join(site, 'yt_dlp_plugins'))
    for name in ('ytm_bridge.py', 'ytm_js.py'):
        shutil.copy2(os.path.join(repo, 'Py', name), os.path.join(site, name))

    # 4. The framework the app links ---------------------------------------
    log('Python.framework')
    if os.path.exists(vendor):
        shutil.rmtree(vendor)
    os.makedirs(vendor)
    shutil.copytree(os.path.join(device, 'Python.framework'),
                    os.path.join(vendor, 'Python.framework'), symlinks=True)

    # 5. Notes for the build log -------------------------------------------
    manifest = {
        'python': PYTHON_TAG,
        'yt_dlp': YT_DLP,
        'yt_dlp_ejs': YT_DLP_EJS,
        'certifi': CERTIFI,
        'runtime': runtime,
        'size_mb': round(tree_size(runtime) / 1048576, 1),
        'framework_mb': round(tree_size(os.path.join(vendor, 'Python.framework')) / 1048576, 1),
    }
    with open(os.path.join(runtime, 'manifest.json'), 'w') as fh:
        json.dump(manifest, fh, indent=2)
    log('done: {size_mb} MB runtime, {framework_mb} MB framework'.format(**manifest))
    return manifest


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--out', default=os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                        help='repository root (PythonRuntime/ and vendor/ go here)')
    parser.add_argument('--cache', default=None, help='download cache (default: .build/python)')
    args = parser.parse_args()
    cache = args.cache or os.path.join(args.out, '.build', 'python')
    build(args.out, cache)


if __name__ == '__main__':
    main()
