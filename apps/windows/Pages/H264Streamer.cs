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
/// Feeds length-prefixed H.264 samples into a MediaStreamSource the player
/// element shows. The queue holds at most two pictures: latency matters
/// more than preserving obsolete frames in an interactive screen session,
/// matching the host queue rule. Created per resolution, because the
/// descriptor is fixed when the source is built.
/// </summary>
internal sealed class H264Streamer
{
    private readonly object _gate = new();
    private readonly Queue<Pending> _queue = new();
    private MediaStreamSourceSampleRequest? _waiting;
    private MediaStreamSourceSampleRequestDeferral? _waitingDeferral;

    public MediaStreamSource Source { get; }

    public uint Width { get; }

    public uint Height { get; }

    private sealed record Pending(byte[] Avcc, bool Key, TimeSpan Stamp);

    public H264Streamer(uint width, uint height)
    {
        Width = width;
        Height = height;
        var properties = VideoEncodingProperties.CreateH264();
        properties.Width = width;
        properties.Height = height;
        Source = new MediaStreamSource(new VideoStreamDescriptor(properties));
        Source.SampleRequested += OnSampleRequested;
    }

    public void Push(byte[] avcc, bool key, TimeSpan stamp)
    {
        MediaStreamSourceSampleRequest? request = null;
        MediaStreamSourceSampleRequestDeferral? deferral = null;
        lock (_gate)
        {
            if (_waiting is not null)
            {
                request = _waiting;
                deferral = _waitingDeferral;
                _waiting = null;
                _waitingDeferral = null;
            }
            else
            {
                while (_queue.Count >= 2)
                {
                    _queue.Dequeue();
                }
                _queue.Enqueue(new Pending(avcc, key, stamp));
                return;
            }
        }
        if (request is not null)
        {
            request.Sample = ToMediaSample(new Pending(avcc, key, stamp));
            deferral?.Complete();
        }
    }

    public void Close()
    {
        MediaStreamSourceSampleRequestDeferral? deferral = null;
        lock (_gate)
        {
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
        args.Request.Sample = ToMediaSample(next);
        deferral.Complete();
    }

    private static MediaStreamSample ToMediaSample(Pending pending)
    {
        var sample = MediaStreamSample.CreateFromBuffer(pending.Avcc.AsBuffer(), pending.Stamp);
        sample.KeyFrame = pending.Key;
        sample.Duration = TimeSpan.FromMilliseconds(33);
        return sample;
    }
}
