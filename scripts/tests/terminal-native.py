#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Exercise the production Mac terminal subclass against the resolved SwiftTerm."""
import argparse
from pathlib import Path
import subprocess
import tempfile
root = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--products', type=Path, default=root / 'target/xcode-debug/Build/Products/Debug')
args = parser.parse_args()
products = args.products.resolve()
with tempfile.TemporaryDirectory(prefix='tokenstat-native-terminal-') as directory:
    work = Path(directory)
    keys = (root / 'apps/mac/Sources/Client/ClientTerminalKeys.swift').read_text()
    (work / 'Keys.swift').write_text(keys[:keys.index('#if !os(macOS)')])
    subprocess.run(['swiftc', '-parse-as-library', '-I', str(products),
        str(root / 'scripts/tests/terminal-native.swift'), str(work / 'Keys.swift'),
        str(root / 'apps/mac/Sources/Features/Terminals/TerminalSelectionView.swift'),
        str(products / 'SwiftTerm.o'), '-o', str(work / 'native-check')], check=True)
    subprocess.run([str(work / 'native-check')], check=True, timeout=45)
