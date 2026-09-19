// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using System.Runtime.InteropServices.WindowsRuntime;
using Windows.Media.Core;
using Windows.Media.MediaProperties;

namespace Tokenstat.Pages;

/// <summary>
/// Feeds Annex-B H.264 samples into a MediaStreamSource the player
/// element shows. A bounded queue preserves reference pictures; after overflow
/// it waits for a keyframe rather than feeding undecodable deltas.
/// Created per resolution, because the
/// descriptor is fixed when the source is built.
/// </summary>
internal sealed class H264Streamer
{
    private readonly object _gate = new();
    private readonly Queue<Pending> _queue = new();
    private bool _needsKeyframe = true;
    private bool _closed;
    private MediaStreamSourceSampleRequest? _waiting;
    private MediaStreamSourceSampleRequestDeferral? _waitingDeferral;

    public MediaStreamSource Source { get; }

    public uint Width { get; }

    public uint Height { get; }

    private sealed record Pending(byte[] AnnexB, bool Key, TimeSpan Stamp);

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

    public void Push(byte[] annexB, bool key, TimeSpan stamp)
    {
        MediaStreamSourceSampleRequest? request = null;
        MediaStreamSourceSampleRequestDeferral? deferral = null;
        lock (_gate)
        {
            if (_closed) return;
            // Dropping a reference picture invalidates every following delta.
            // Bound latency, but resume only at a fresh independently decodable frame.
            if (_queue.Count >= 30)
            {
                _queue.Clear();
                _needsKeyframe = true;
            }
            if (_needsKeyframe && !key) return;
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
                _queue.Enqueue(new Pending(annexB, key, stamp));
                return;
            }
        }
        if (request is not null)
        {
            Complete(request, deferral, new Pending(annexB, key, stamp));
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
        deferral?.Complete();
    }

    private void OnSampleRequested(MediaStreamSource sender, MediaStreamSourceSampleRequestedEventArgs args)
    {
        var deferral = args.Request.GetDeferral();
        Pending? next = null;
        lock (_gate)
        {
            if (_closed) { deferral.Complete(); return; }
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
        catch
        {
            lock (_gate)
            {
                if (!_closed) Source.NotifyError(MediaStreamSourceErrorStatus.DecodeError);
            }
        }
        finally { deferral?.Complete(); }
    }

    private static MediaStreamSample ToMediaSample(Pending pending)
    {
        var sample = MediaStreamSample.CreateFromBuffer(pending.AnnexB.AsBuffer(), pending.Stamp);
        sample.KeyFrame = pending.Key;
        // Timestamps come from capture; do not pretend every quality preset is 30 fps.
        return sample;
    }
}
