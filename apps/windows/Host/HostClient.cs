// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using System.IO.Pipes;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Tokenstat.Host;

internal sealed class HostException : Exception
{
    public string Code { get; }

    public HostException(string code, string message) : base(message)
    {
        Code = code;
    }
}

/// <summary>
/// Line-delimited JSON over the per-user named pipe. Same framing as the
/// unix socket: one request line, one response line, ids echoed back.
/// </summary>
internal sealed class HostClient
{
    private readonly object _gate = new();
    private long _nextId = 1;
    private NamedPipeClientStream? _pipe;
    private StreamReader? _reader;
    private StreamWriter? _writer;

    public static string PipeName
    {
        get
        {
            var user = Environment.GetEnvironmentVariable("USERNAME")
                ?? Environment.UserName;
            var safe = new StringBuilder(user.Length);
            foreach (var c in user)
            {
                if (char.IsAsciiLetterOrDigit(c) || c is '.' or '_' or '-')
                {
                    safe.Append(c);
                }
                else
                {
                    safe.Append('_');
                }
            }
            if (safe.Length == 0)
            {
                safe.Append("user");
            }
            return $"ai.tokenstat.hostd.{safe}";
        }
    }

    public JsonNode Call(string method, JsonNode? parameters = null, TimeSpan? patience = null)
    {
        var timeout = patience ?? TimeSpan.FromSeconds(60);
        var id = Interlocked.Increment(ref _nextId);
        var payload = new JsonObject
        {
            ["id"] = id,
            ["method"] = method,
            ["params"] = parameters ?? new JsonObject(),
        };
        var line = payload.ToJsonString();

        lock (_gate)
        {
            EnsureConnected(timeout);
            try
            {
                _writer!.WriteLine(line);
                _writer.Flush();
                _pipe!.ReadTimeout = (int)Math.Min(timeout.TotalMilliseconds, int.MaxValue);
                var response = _reader!.ReadLine();
                if (response is null)
                {
                    Drop();
                    throw new HostException("eof", "The host closed the connection.");
                }
                return Decode(method, response);
            }
            catch (IOException ex)
            {
                Drop();
                throw new HostException("io", ex.Message);
            }
        }
    }

    public Task<JsonNode> CallAsync(string method, JsonNode? parameters = null, TimeSpan? patience = null) =>
        Task.Run(() => Call(method, parameters, patience));

    private void EnsureConnected(TimeSpan timeout)
    {
        if (_pipe is { IsConnected: true } && _reader is not null && _writer is not null)
        {
            return;
        }
        Drop();
        var pipe = new NamedPipeClientStream(
            ".",
            PipeName,
            PipeDirection.InOut,
            PipeOptions.None);
        try
        {
            pipe.Connect((int)Math.Min(Math.Max(timeout.TotalMilliseconds, 250), 10_000));
        }
        catch (TimeoutException)
        {
            pipe.Dispose();
            throw new HostException("connect", $"Could not reach {PipeName}.");
        }
        pipe.ReadMode = PipeTransmissionMode.Byte;
        _pipe = pipe;
        _reader = new StreamReader(pipe, new UTF8Encoding(false), detectEncodingFromByteOrderMarks: false, bufferSize: 4096, leaveOpen: true);
        _writer = new StreamWriter(pipe, new UTF8Encoding(false), bufferSize: 4096, leaveOpen: true)
        {
            NewLine = "\n",
            AutoFlush = true,
        };
    }

    private void Drop()
    {
        try { _writer?.Dispose(); } catch { /* ignore */ }
        try { _reader?.Dispose(); } catch { /* ignore */ }
        try { _pipe?.Dispose(); } catch { /* ignore */ }
        _writer = null;
        _reader = null;
        _pipe = null;
    }

    private static JsonNode Decode(string method, string raw)
    {
        JsonNode node;
        try
        {
            node = JsonNode.Parse(raw) ?? new JsonObject();
        }
        catch (JsonException ex)
        {
            throw new HostException("decode", $"Could not read the response to {method}: {ex.Message}");
        }
        var ok = node["ok"]?.GetValue<bool>() ?? false;
        if (ok)
        {
            return node["result"] ?? new JsonObject();
        }
        var error = node["error"];
        throw new HostException(
            error?["code"]?.GetValue<string>() ?? "core",
            error?["message"]?.GetValue<string>() ?? "The tokenstat host rejected the call.");
    }
}
