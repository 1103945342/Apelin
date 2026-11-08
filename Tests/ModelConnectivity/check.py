#!/usr/bin/env python3
"""Standalone report regression, not a replacement for make check or SDK tests.

Run from the repository root. On iOS pass --ios and --entitlements with the
Tool.entitlements from Apelin's device-executables skill. Output stays in build/.
"""
import argparse
from pathlib import Path
import re
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('--ios', action='store_true')
parser.add_argument('--entitlements')
args = parser.parse_args()
if args.ios and not args.entitlements:
    parser.error('--ios requires --entitlements; never run an unsigned executable')
if args.entitlements and not Path(args.entitlements).is_file():
    parser.error('entitlements file does not exist')
out = Path('build/model-connectivity')
out.mkdir(parents=True, exist_ok=True)
wire = Path('Packages/ApelinKit/Sources/ApelinProtocol/Operations/AgentModelTest.swift').read_text()
# The wire values verbatim; request/service declarations need the full package.
wire = wire[:wire.index('public struct AgentModelTestRequest')] + wire[
    wire.index('public struct AgentModelTestResponse'):wire.index('public extension ApelinService')]
report = Path('Packages/ApelinAgent/Sources/ApelinAgentWorker/ModelTestReport.swift').read_text()
report = report.replace('import ApelinProtocol\n', '')
check = Path('Tests/ModelConnectivity/Check.swift').read_text()
# Swift 5.10 on the device lacks Swift 6's trailing call-argument commas.
source = re.sub(r',(\s*\))', r'\1', wire + '\n' + report + '\n' + check)
(out / 'Check.swift').write_text(source)
command = ['swiftc', '-parse-as-library', '-strict-concurrency=complete', '-warnings-as-errors']
if args.ios:
    command += ['-target', 'arm64-apple-ios16.0']
command += [str(out / 'Check.swift'), '-o', str(out / 'check')]
subprocess.run(command, check=True)
if args.ios:
    subprocess.run(['ldid', '-S' + args.entitlements, str(out / 'check')], check=True)
subprocess.run(['./' + str(out / 'check')], check=True)
