// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using System.Runtime.InteropServices.WindowsRuntime;
using Windows.Media.Core;
using Windows.Media.MediaProperties;

namespace Tokenstat.Pages;

internal sealed class H264Streamer
{
    private readonly object _gate = new();
    private readonly Queue<Pending> _queue = new();
    private bool _needsKeyframe = true;
    private bool _closed;
    private ulong? _lastSequence;
    private MediaStreamSourceSampleRequest? _waiting;
    private MediaStreamSourceSampleRequestDeferral? _waitingDeferral;

    public MediaStreamSource Source { get; }

    public uint Width { get; }

    public uint Height { get; }

    private sealed record Pending(byte[] AnnexB, bool Key, TimeSpan Stamp, bool Discontinuous);

    public H264Streamer(uint width, uint height)
    {
        Width = width;
        Height = height;
        var properties = VideoEncodingProperties.CreateH264();
        properties.Width = width;
        properties.Height = height;
        properties.FrameRate.Numerator = 30;
        properties.FrameRate.Denominator = 1;
        Source = new MediaStreamSource(new VideoStreamDescriptor(properties))
        {
            CanSeek = false,
            BufferTime = TimeSpan.Zero,
        };
        Source.SampleRequested += OnSampleRequested;
    }

    public void Push(byte[] annexB, bool key, TimeSpan stamp, ulong? sequence = null)
    {
        MediaStreamSourceSampleRequest? request = null;
        MediaStreamSourceSampleRequestDeferral? deferral = null;
        Pending pending;
        lock (_gate)
        {
            if (_closed) return;
            if (sequence is ulong current)
            {
                if (_lastSequence is ulong previous && (previous == ulong.MaxValue || current != previous + 1))
                {
                    _queue.Clear();
                    _needsKeyframe = true;
                }
                _lastSequence = current;
            }
            if (_queue.Count >= 30)
            {
                _queue.Clear();
                _needsKeyframe = true;
            }
            if (_needsKeyframe && !key) return;
            pending = new Pending(annexB, key, stamp, _needsKeyframe);
            _needsKeyframe = false;
            if (_waiting is not null)
            {
                request = _waiting;
                deferral = _waitingDeferral;
                _waiting = null;
                _waitingDeferral = null;
            }
            else
            {
                _queue.Enqueue(pending);
                return;
            }
        }
        if (request is not null)
        {
            Complete(request, deferral, pending);
        }
    }

    public void Close()
    {
        MediaStreamSourceSampleRequestDeferral? deferral = null;
        lock (_gate)
        {
            _closed = true;
            Source.SampleRequested -= OnSampleRequested;
            _queue.Clear();
            deferral = _waitingDeferral;
            _waiting = null;
            _waitingDeferral = null;
        }
        CompleteDeferral(deferral);
    }

    private void OnSampleRequested(MediaStreamSource sender, MediaStreamSourceSampleRequestedEventArgs args)
    {
        MediaStreamSourceSampleRequestDeferral deferral;
        try { deferral = args.Request.GetDeferral(); }
        catch (System.Runtime.InteropServices.COMException) { ReportDecodeError(); return; }
        catch (ObjectDisposedException) { ReportDecodeError(); return; }
        Pending? next = null;
        lock (_gate)
        {
            if (_closed) { CompleteDeferral(deferral); return; }
            if (_queue.Count > 0)
            {
                next = _queue.Dequeue();
            }
            else
            {
                _waiting = args.Request;
                _waitingDeferral = deferral;
                return;
            }
        }
        Complete(args.Request, deferral, next);
    }

    private void Complete(MediaStreamSourceSampleRequest request, MediaStreamSourceSampleRequestDeferral? deferral, Pending pending)
    {
        try
        {
            lock (_gate)
            {
                if (!_closed) request.Sample = ToMediaSample(pending);
            }
        }
        catch { ReportDecodeError(); }
        finally { CompleteDeferral(deferral); }
    }

    private void ReportDecodeError()
    {
        lock (_gate)
        {
            if (_closed) return;
            try { Source.NotifyError(MediaStreamSourceErrorStatus.DecodeError); }
            catch (System.Runtime.InteropServices.COMException) { }
            catch (ObjectDisposedException) { }
        }
    }

    private static void CompleteDeferral(MediaStreamSourceSampleRequestDeferral? deferral)
    {
        try { deferral?.Complete(); }
        catch (System.Runtime.InteropServices.COMException) { }
        catch (ObjectDisposedException) { }
    }

    private static MediaStreamSample ToMediaSample(Pending pending)
    {
        var sample = MediaStreamSample.CreateFromBuffer(pending.AnnexB.AsBuffer(), pending.Stamp);
        sample.KeyFrame = pending.Key;
        sample.Discontinuous = pending.Discontinuous;
        return sample;
    }
}
