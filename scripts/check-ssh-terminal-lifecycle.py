#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Exercise the actual stop method without a shell or native emulator."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
source = (root / 'apps/mac/Sources/Features/Machines/SSHLiveTerminal.swift').read_text()
start = source.index('    func stop() {')
brace = source.index('{', start)
depth = 1
end = brace + 1
while depth:
    depth += (source[end] == '{') - (source[end] == '}')
    end += 1
stop = source[start:end]
swift = '''import Foundation
@MainActor final class SSHLiveTerminal {
    static var calls = 0
    static var pending: CheckedContinuation<Bool, Never>?
    func closeRemote() async -> Bool {
        Self.calls += 1
        return await withCheckedContinuation { Self.pending = $0 }
    }
''' + stop + '''
}
@main struct Check {
    @MainActor static func main() async {
        var terminal: SSHLiveTerminal? = SSHLiveTerminal()
        weak let original = terminal
        terminal?.stop()
        terminal = nil
        for _ in 0..<10000 {
            if SSHLiveTerminal.pending != nil { break }
            await Task.yield()
        }
        precondition(SSHLiveTerminal.calls == 1 && original != nil,
                     "Releasing the setup owner canceled its shell cleanup")
        SSHLiveTerminal.pending?.resume(returning: true)
        SSHLiveTerminal.pending = nil
        for _ in 0..<10000 {
            if original == nil { break }
            await Task.yield()
        }
        precondition(original == nil, "Completed cleanup retained the terminal")
        print("SSH stop: exact owner survives queued cleanup and retires afterward")
    }
}
'''
with tempfile.TemporaryDirectory() as directory:
    work = Path(directory)
    (work / 'Check.swift').write_text(swift)
    subprocess.run(['swiftc', '-parse-as-library', '-swift-version', '5', str(work / 'Check.swift'), '-o', str(work / 'check')], check=True)
    subprocess.run([str(work / 'check')], check=True)
assert 'self.reader.acceptsInput(epoch)' in source
assert 'session.acceptsFocus(token, epoch: epoch)' in source
assert 'context.coordinator.token = token' in source
assert 'closeTicket == token' in source
print('SSH input/focus/close ownership source guards passed')
