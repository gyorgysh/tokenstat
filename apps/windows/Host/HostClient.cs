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
    private long _nextId = 1;
    private readonly Action? _recover;
    private readonly object _recoveryGate = new();
    private DateTime _lastRecovery;

    public HostClient(Action? recover = null) => _recover = recover;

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

        // hostd shares its session across connections. Give each request its
        // own pipe so a scan or remote dial cannot queue every page behind it.
        using var pipe = new NamedPipeClientStream(
            ".", PipeName, PipeDirection.InOut, PipeOptions.Asynchronous);
        try
        {
            try
            {
                pipe.Connect(1000);
            }
            catch (TimeoutException) when (_recover is not null)
            {
                // Recover only before sending. Replaying an interrupted write
                // could create a second terminal, workspace or other mutation.
                lock (_recoveryGate)
                {
                    // All pages may notice the same outage. One restart
                    // attempt serves them all, including when startup fails.
                    if (DateTime.UtcNow - _lastRecovery > TimeSpan.FromSeconds(15))
                    {
                        try { _recover(); }
                        finally { _lastRecovery = DateTime.UtcNow; }
                    }
                }
                pipe.Connect(1000);
            }
            using var reader = new StreamReader(pipe, new UTF8Encoding(false), false, 4096, leaveOpen: true);
            using var deadline = new CancellationTokenSource(timeout);
            // Bound writes as well as reads; a live but stuck helper must not
            // leave a page waiting indefinitely.
            pipe.WriteAsync(Encoding.UTF8.GetBytes(line + "\n"), deadline.Token).AsTask().GetAwaiter().GetResult();
            var response = reader.ReadLineAsync(deadline.Token).AsTask().GetAwaiter().GetResult();
            if (response is null)
            {
                throw new HostException("eof", "The host closed the connection. Try again.");
            }
            return Decode(method, response);
        }
        catch (OperationCanceledException)
        {
            throw new HostException("timeout", $"The host did not answer {method} in time. Try again.");
        }
        catch (TimeoutException)
        {
            throw new HostException("connect", "The local host could not be started. Try again or reopen tokenstat.");
        }
        catch (IOException ex)
        {
            throw new HostException("io", ex.Message);
        }
    }

    public Task<JsonNode> CallAsync(string method, JsonNode? parameters = null, TimeSpan? patience = null) =>
        Task.Run(() => Call(method, parameters, patience));

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
            var result = node["result"];
            if (result is null || result.GetValueKind() == JsonValueKind.Null)
            {
                return new JsonObject();
            }
            return result;
        }
        var error = node["error"];
        throw new HostException(
            error?["code"]?.GetValue<string>() ?? "core",
            error?["message"]?.GetValue<string>() ?? "The tokenstat host rejected the call.");
    }
}
