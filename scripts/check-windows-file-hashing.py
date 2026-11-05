#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Check Windows file hashing thread ownership, exact bytes and cancellation."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'apps/windows/Pages/ChatPage.Files.cs').read_text()
if '    private static Task<long> ReadFileHashAsync(' in source:
    start = source.index('    private static Task<long> ReadFileHashAsync(')
    end, depth = source.index('{', start) + 1, 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}'); end += 1
    method = source[start:end]
else:
    # Run the previous inline upload loop to reproduce its thread ownership.
    start = source.index('            var hashBuffer = new byte[FileChunkBytes];')
    end = source.index('            var hash = Convert.ToHexString', start)
    body = source[start:end].replace('cancel.Token', 'cancellation')
    method = 'static async Task<long> ReadFileHashAsync(Stream stream, IncrementalHash hasher, long expectedSize, CancellationToken cancellation) {' + body + 'return hashedBytes;}'
code = r'''
using System.Security.Cryptography;
class CheckedStream(byte[] bytes) : MemoryStream(bytes) {
    public int Owner = Environment.CurrentManagedThreadId, Reads;
    public bool RejectOwner = true;
    public CancellationTokenSource? CancelAfterRead;
    public override ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellation = default) {
        if (RejectOwner && Environment.CurrentManagedThreadId == Owner) throw new Exception("Hash read ran on its UI owner thread");
        Reads++;
        // Cached reads may finish synchronously; cancellation is still required.
        var count = Read(buffer.Span);
        CancelAfterRead?.Cancel();
        return ValueTask.FromResult(count);
    }
}
class Checks {
    const int FileChunkBytes = 512 * 1024;
''' + method + r'''
    static void Require(bool value, string reason) { if (!value) throw new Exception(reason); }
    static async Task Main() {
        var bytes = new byte[4 * FileChunkBytes + 117]; new Random(7).NextBytes(bytes);
        using (var stream = new CheckedStream(bytes)) using (var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256)) {
            var count = await ReadFileHashAsync(stream, hash, bytes.Length, CancellationToken.None);
            Require(count == bytes.Length && stream.Position == count, "Hashing changed file position or byte count");
            Require(hash.GetHashAndReset().SequenceEqual(SHA256.HashData(bytes)), "File hash changed");
        }
        foreach (var size in new[] { 0, bytes.Length - 1, bytes.Length + 1 }) {
            using var stream = new CheckedStream(bytes) { RejectOwner = false };
            using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
            try { await ReadFileHashAsync(stream, hash, size, CancellationToken.None); throw new Exception("Changed file size was accepted"); } catch (IOException) { }
        }
        foreach (var early in new[] { true, false }) {
            using var cancel = new CancellationTokenSource();
            using var stream = new CheckedStream(bytes) { RejectOwner = false, CancelAfterRead = early ? null : cancel };
            using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
            if (early) cancel.Cancel();
            try { await ReadFileHashAsync(stream, hash, bytes.Length, cancel.Token); throw new Exception("Hashing ignored cancellation"); } catch (OperationCanceledException) { }
            Require(stream.Reads <= (early ? 0 : 1), "Cancelled hashing kept reading cached bytes");
        }
        // A resumed download continues the same digest with newly received bytes.
        var prefix = bytes[..(FileChunkBytes + 3)];
        using (var stream = new CheckedStream(prefix) { RejectOwner = false }) using (var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256)) {
            await ReadFileHashAsync(stream, hash, prefix.Length, CancellationToken.None);
            hash.AppendData(bytes.AsSpan(prefix.Length));
            Require(hash.GetHashAndReset().SequenceEqual(SHA256.HashData(bytes)), "Resumed download hash changed");
        }
        Console.WriteLine("Windows file hashing: worker thread, exact bytes, changed size, preflight/mid-read cancellation and resumed digest passed");
    }
}
'''
with tempfile.TemporaryDirectory(prefix='tokenstat-hashing-check-') as directory:
    work = Path(directory); (work / 'Program.cs').write_text(code)
    (work / 'Checks.csproj').write_text('<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><OutputType>Exe</OutputType><TargetFramework>net8.0</TargetFramework><ImplicitUsings>enable</ImplicitUsings><Nullable>enable</Nullable></PropertyGroup></Project>')
    subprocess.run(['dotnet', 'run', '--project', str(work / 'Checks.csproj'), '-c', 'Release'], check=True)
