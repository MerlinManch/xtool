"""Deploy the PE import closure beside each program, then test without build PATH.

Uses only Python's standard library; no dumpbin, pefile or SDK is needed to read
imports. Windows system DLLs stay in Windows. Missing imports fail packaging.
"""
import argparse
from collections import deque
import hashlib
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile


def imports(path):
    data = path.read_bytes()
    pe = struct.unpack_from('<I', data, 0x3c)[0]
    if data[:2] != b'MZ' or data[pe:pe + 4] != b'PE\0\0':
        raise ValueError(f'Invalid PE image: {path}')
    machine, count = struct.unpack_from('<HH', data, pe + 4)
    optional_size = struct.unpack_from('<H', data, pe + 20)[0]
    optional = pe + 24
    if machine != 0x8664 or struct.unpack_from('<H', data, optional)[0] != 0x20b:
        raise ValueError(f'Expected x64 PE32+ image: {path}')
    section_table = optional + optional_size
    sections = [struct.unpack_from('<IIII', data, section_table + i * 40 + 8)
                for i in range(count)]

    def offset(rva):
        for size, address, raw_size, raw in sections:
            if address <= rva < address + max(size, raw_size):
                return raw + rva - address
        raise ValueError(f'Unmapped RVA {rva:x}: {path}')

    def name(rva):
        start = offset(rva)
        return data[start:data.index(b'\0', start)].decode('ascii')

    directories = struct.unpack_from('<I', data, optional + 108)[0]
    result = []
    for index, stride in ((1, 20), (13, 32)):
        if directories <= index:
            continue
        rva, size = struct.unpack_from('<II', data, optional + 112 + index * 8)
        if not rva or not size:
            continue
        cursor = offset(rva)
        while any(data[cursor:cursor + stride]):
            if index == 1:
                result.append(name(struct.unpack_from('<I', data, cursor + 12)[0]))
            else:
                attributes, name_rva = struct.unpack_from('<II', data, cursor)
                if not attributes & 1:
                    raise ValueError(f'Unsupported VA delay import: {path}')
                result.append(name(name_rva))
            cursor += stride
    return result


def index(directory):
    if not directory.is_dir():
        return {}
    return {p.name.lower(): p for p in directory.iterdir()
            if p.is_file() and p.suffix.lower() == '.dll'}


def bundle(root):
    swift = shutil.which('swift.exe')
    if not swift:
        raise RuntimeError('Swift used to build the CLI is required to collect runtime DLLs')
    info = json.loads(subprocess.check_output([swift, '-print-target-info'], text=True))
    directories = [Path(p) for p in info['paths']['runtimeLibraryPaths']]
    directories += [Path(swift).parent]
    directories += [Path(p) for p in os.environ.get('PATH', '').split(os.pathsep) if p]
    system = Path(os.environ['SystemRoot']) / 'System32'
    system_index = index(system)
    candidates = {}
    for directory in directories:
        if directory.resolve() != system.resolve():
            for name, path in index(directory).items():
                candidates.setdefault(name, path)
    records = {}
    # Separate import closures matter: the DLL loader searches beside the
    # executable, not recursively in the distribution's bin directory.
    for executable in sorted(root.rglob('*.exe')):
        local = index(executable.parent)
        queue = deque([executable, *local.values()])
        visited = set()
        while queue:
            image = queue.popleft()
            if image.name.lower() in visited:
                continue
            visited.add(image.name.lower())
            for name in imports(image):
                key = name.lower()
                if key.startswith(('api-ms-win-', 'ext-ms-win-')):
                    continue
                if key in local:
                    queue.append(local[key])
                    continue
                if key in system_index:
                    continue
                source = candidates.get(key)
                if source is None:
                    raise RuntimeError(f'{image}: missing imported DLL {name}')
                # Validate architecture before deploying an import selected from PATH.
                imports(source)
                destination = executable.parent / source.name
                shutil.copy2(source, destination)
                local[key] = destination
                queue.append(destination)
                records[str(destination.relative_to(root))] = {
                    'source': str(source),
                    'sha256': hashlib.sha256(destination.read_bytes()).hexdigest(),
                }
    (root / 'runtime-files.json').write_text(
        json.dumps(records, indent=2) + '\n', encoding='utf-8')
    print(f'Deployed {len(records)} runtime DLLs')


def smoke(root):
    # os.environ is case-insensitive on Windows, an ordinary copied dict is not.
    environment = {key.upper(): value for key, value in os.environ.items()}
    environment['PATH'] = str(Path(environment['SYSTEMROOT']) / 'System32')
    for name in list(environment):
        if name.upper().startswith(('SWIFT', 'SDKROOT', 'DEVELOPER_DIR')):
            environment.pop(name)
    # Run from outside the package as well: the current working directory must
    # not supply DLLs accidentally. Assert output, not only successful exit.
    with tempfile.TemporaryDirectory(prefix='xtool clean runtime ') as working:
        for argument in ('--help', '--version'):
            result = subprocess.run([str((root / 'bin/xtool.exe').resolve()), argument],
                                    env=environment, cwd=working, capture_output=True,
                                    text=True, encoding='utf-8', errors='replace', timeout=30)
            if result.returncode or not result.stdout.strip():
                code = result.returncode & 0xffffffff
                raise RuntimeError(f'Clean-environment CLI {argument} failed: '
                                   f'0x{code:08X}\n{result.stdout}\n{result.stderr}')
            if argument == '--help' and ('USAGE:' not in result.stdout or 'xtool' not in result.stdout):
                raise RuntimeError(f'Unexpected help output: {result.stdout}')
            print(f'Clean-environment CLI {argument}: PASS')
        environment['XTOOL_NATIVE_MACRO_SERVER'] = str(
            (root / 'bin/windows-macros/OpenAppleMacrosServer.exe').resolve())
        subprocess.run([os.sys.executable, '-m', 'unittest', 'discover', '-s',
                        str(Path(__file__).resolve().parent / 'macro-tests'), '-v'],
                       env=environment, cwd=working, check=True, timeout=90)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root', type=Path)
    parser.add_argument('--smoke', action='store_true')
    args = parser.parse_args()
    if os.name != 'nt':
        parser.error('Native Windows is required')
    if args.smoke:
        smoke(args.root.resolve())
    else:
        bundle(args.root.resolve())
