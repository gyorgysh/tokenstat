// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with ProcessOutput.swift.
import Foundation

@main struct ProcessOutputTests {
    static func main() throws {
        DispatchQueue.global().asyncAfter(deadline: .now() + 15) {
            fatalError("Subprocess output capture deadlocked")
        }
        // Fill stderr before stdout, then reverse the order. Both streams
        // exceed pipe capacity and remain separate in the captured result.
        for first in ["stdout", "stderr"] {
            let script = """
            if [ "$1" = stderr ]; then
                /usr/bin/head -c 262144 /dev/zero >&2
                /usr/bin/head -c 262144 /dev/zero
            else
                /usr/bin/head -c 262144 /dev/zero
                /usr/bin/head -c 262144 /dev/zero >&2
            fi
            printf 'out'
            printf 'err' >&2
            exit 7
            """
            let result = try ProcessOutput.run("/bin/sh", ["-c", script, "fixture", first])
            assert(result.status == 7)
            assert(result.output.utf8.count == 262147 && result.output.hasSuffix("out"))
            assert(result.errors.utf8.count == 262147 && result.errors.hasSuffix("err"))
        }
        do {
            _ = try ProcessOutput.run("/nonexistent-tokenstat-test-tool", [])
            assertionFailure("A missing executable must fail")
        } catch {}
        print("Process output: both pipe orders, large output, separate diagnostics, exit status and launch failure passed")
    }
}
