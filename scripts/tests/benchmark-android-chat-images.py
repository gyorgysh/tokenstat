#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Exercise the actual benchmark runner without a device or a Gradle build."""
from pathlib import Path
import json
import os
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
adb = r'''#!/usr/bin/env python3
from pathlib import Path
import json, os, shutil, sys
base = Path(os.environ['MOCK_DEVICE'])
args = sys.argv[1:]
with (base / 'calls.jsonl').open('a') as log:
    log.write(json.dumps(args) + '\n')
assert args[:2] == ['-s', 'qa-only'], args
args = args[2:]
if args[:1] == ['install']:
    sys.exit(0)
if args[:3] == ['shell', 'am', 'instrument']:
    folder = args[args.index('chatImageBenchmark') + 1]
    if os.environ['MOCK_RESULT'] != 'missing':
        (base / 'files' / folder / 'benchmark.json').write_text('{"run":"fresh"}')
    if os.environ['MOCK_RESULT'] == 'failure':
        print('FAILURES!!!\nTests run: 1, Failures: 1\nINSTRUMENTATION_CODE: -1')
    else:
        print('OK (1 test)\nINSTRUMENTATION_CODE: -1')
    # Android's shell command exit status alone does not indicate JUnit success.
    sys.exit(0)
assert args[:3] == ['shell', 'run-as', 'ai.tokenstat.tokenstat'], args
args = args[3:]
if args[:2] == ['mkdir', '-p']:
    (base / args[2]).mkdir(parents=True)
elif args[:2] == ['rm', '-rf']:
    shutil.rmtree(base / args[2], ignore_errors=True)
elif args[:2] == ['sh', '-c']:
    sys.stdin.buffer.read()
elif args[:1] == ['cat']:
    source = base / args[1]
    if not source.is_file():
        sys.exit(1)
    print(source.read_text())
else:
    raise AssertionError(args)
'''

for result in ('success', 'failure', 'missing'):
    with tempfile.TemporaryDirectory(prefix='tokenstat-image-benchmark-runner-') as temp:
        fixture = Path(temp)
        checkout = fixture / 'checkout'
        scripts = checkout / 'scripts'
        (scripts / 'benchmarks').mkdir(parents=True)
        shutil.copy2(root / 'scripts/benchmark-android-chat-images.sh', scripts)
        shutil.copy2(root / 'scripts/benchmarks/AndroidChatImages.kt', scripts / 'benchmarks')
        android = checkout / 'apps/android'
        generated = android / 'app/src/androidTest/java/ai/tokenstat/tokenstat/ui/workspace/AndroidChatImages.kt'
        generated.parent.mkdir(parents=True)
        gradle = android / 'gradlew'
        gradle.write_text('#!/usr/bin/env bash\nexit 0\n')
        gradle.chmod(0o755)
        sdk = fixture / 'sdk'
        (sdk / 'platform-tools').mkdir(parents=True)
        command = sdk / 'platform-tools/adb'
        command.write_text(adb)
        command.chmod(0o755)
        device = fixture / 'device'
        (device / 'files').mkdir(parents=True)
        stale = device / 'files/chat-image-benchmark.json'
        stale.write_text('{"run":"stale"}')
        images = fixture / 'images'
        images.mkdir()
        (images / 'image.png').write_bytes(b'local-fixture')
        process = subprocess.run(['bash', str(scripts / 'benchmark-android-chat-images.sh'), str(images), 'qa-only'],
            text=True, capture_output=True, env=os.environ | {
                'ANDROID_SDK_ROOT': str(sdk), 'MOCK_DEVICE': str(device), 'MOCK_RESULT': result,
            })
        calls = [json.loads(line) for line in (device / 'calls.jsonl').read_text().splitlines()]
        reads = [args[-1] for args in calls if 'cat' in args]
        assert (process.returncode == 0) == (result == 'success'), (result, process.stdout, process.stderr)
        assert '"run":"stale"' not in process.stdout
        assert all(path.startswith('files/chat-perf-') and path.endswith('/benchmark.json') for path in reads), reads
        if result == 'success':
            assert '"run":"fresh"' in process.stdout and len(reads) == 1
        elif result == 'failure':
            assert not reads, 'A failed JUnit result must not publish even a freshly written report'
        assert stale.is_file(), 'Cleanup must stay within this run\'s private fixture folder'
        assert not list((device / 'files').glob('chat-perf-*'))
        assert not generated.exists(), 'The temporary benchmark source must be removed'

print('Android benchmark runner: fresh report, exit-zero JUnit failure, missing report and cleanup passed')
