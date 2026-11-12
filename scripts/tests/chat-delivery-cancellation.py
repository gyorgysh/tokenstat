#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Check production delivery classification for cancellation and wire failures."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / 'apps/mac/Sources/Bridge/Bridge.swift').read_text()
start = source.index('    private static func isTimeout(')
timeout = source[start:source.index('\n    /// Whether a transport error means the daemon is gone', start)]
start = source.index('    static func isDeliveryUnknown(')
delivery = source[start:source.index('\n    /// Whether an error means the host was unreachable', start)]
fixture = r'''
import Foundation
enum BridgeError: Error {
    case decoding(method: String, underlying: String)
    case core(code: String, message: String)
}
enum Bridge {
TIMEOUT
DELIVERY
}
@main struct Test {
    static func main() {
        precondition(Bridge.isDeliveryUnknown(CancellationError()))
        precondition(Bridge.isDeliveryUnknown(BridgeError.core(code: "host_timeout", message: "")))
        precondition(Bridge.isDeliveryUnknown(BridgeError.decoding(method: "chat.send", underlying: "")))
        precondition(!Bridge.isDeliveryUnknown(BridgeError.core(code: "host_unreachable", message: "")))
        precondition(!Bridge.isDeliveryUnknown(BridgeError.core(code: "conversation_changed", message: "")))
        print("Cancelled or unanswered sends require a receipt; definite refusals remain retryable")
    }
}
'''.replace('TIMEOUT', timeout).replace('DELIVERY', delivery)
with tempfile.TemporaryDirectory(prefix='tokenstat-delivery-') as directory:
    path = Path(directory)
    (path / 'Test.swift').write_text(fixture)
    subprocess.run(['swiftc', '-parse-as-library', str(path / 'Test.swift'), '-o', str(path / 'test')], check=True)
    subprocess.run([str(path / 'test')], check=True)
