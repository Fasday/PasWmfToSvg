"""Сборка проектов и проверка модулей PasWmfToSvg компилятором Delphi из командной строки (Windows).

Использование:
  python Tools/build.py <проект.dpr | модуль.pas> [--platform P] [--output ПАПКА] [--define ИМЯ ...]

- P: win32 (по умолчанию), win64, linux64, osx64, osxarm64, android64, iosarm64.
- .dpr - программа (для Windows); .pas - только компиляция модуля в .dcu, без компоновки: так проверяется сборка
  ядра под другие платформы без их SDK.
- Delphi - из переменной BDS или последняя установленная (C:\\Program Files (x86)\\Embarcadero\\Studio\\NN.0).
- Результат - в новой папке (по умолчанию временная); там же build.log и build_report.json.
"""
import argparse
import glob
import json
import os
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
COMPILERS = {'win32': 'dcc32.exe', 'win64': 'dcc64.exe', 'linux64': 'dcclinux64.exe', 'osx64': 'dccosx64.exe',
             'osxarm64': 'dccosxarm64.exe', 'android64': 'dccaarm64.exe', 'iosarm64': 'dcciosarm64.exe'}
NAMESPACES = 'System;Winapi;System.Win;Vcl;Vcl.Imaging;Posix;Macapi;Androidapi;iOSapi'


def bds():
    if os.environ.get('BDS'):
        return os.environ['BDS']
    found = sorted(glob.glob(r'C:\Program Files (x86)\Embarcadero\Studio\*.0'),
                   key=lambda p: float(os.path.basename(p)))
    if not found:
        raise SystemExit('Delphi не найден: задайте переменную BDS')
    return found[-1]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('project')
    ap.add_argument('--platform', default='win32', choices=sorted(COMPILERS))
    ap.add_argument('--output')
    ap.add_argument('--define', action='append', default=[])
    args = ap.parse_args()
    project = os.path.abspath(args.project)
    out = os.path.abspath(args.output) if args.output else tempfile.mkdtemp(prefix='paswmftosvg_')
    os.makedirs(out, exist_ok=True)
    dcu = os.path.join(out, 'dcu')
    os.makedirs(dcu, exist_ok=True)
    search = [os.path.join(ROOT, 'Source'), os.path.dirname(project)]
    cmd = [os.path.join(bds(), 'bin', COMPILERS[args.platform]), '-B', '-Q', '-E' + out, '-N0' + dcu,
           '-U' + ';'.join(search), '-I' + ';'.join(search), '-R' + ';'.join(search), '-NS' + NAMESPACES]
    for d in args.define:
        cmd.append('-D' + d)
    cmd.append(project)
    started = time.time()
    proc = subprocess.run(cmd, cwd=os.path.dirname(project), capture_output=True)
    log = (proc.stdout + proc.stderr).decode('cp1251', errors='replace')
    with open(os.path.join(out, 'build.log'), 'w', encoding='utf-8') as f:
        f.write(log)
    lines = log.splitlines()
    errors = [x for x in lines if ' Error: ' in x or ' Fatal: ' in x or x.startswith('Fatal')]
    warnings = [x for x in lines if ' Warning: ' in x or ' Hint: ' in x]
    exe = os.path.join(out, os.path.splitext(os.path.basename(project))[0] + '.exe')
    report = {'project': project, 'platform': args.platform, 'exit_code': proc.returncode, 'errors': errors,
              'warnings': warnings, 'exe': exe if os.path.exists(exe) else None,
              'seconds': round(time.time() - started, 1), 'output': out}
    with open(os.path.join(out, 'build_report.json'), 'w', encoding='utf-8') as f:
        json.dump(report, f, ensure_ascii=False, indent=2)
    print(json.dumps({k: report[k] for k in ('platform', 'exit_code', 'exe', 'output')}, ensure_ascii=False))
    for line in errors[:30] + warnings[:30]:
        print(line)
    return proc.returncode


if __name__ == '__main__':
    sys.exit(main())
