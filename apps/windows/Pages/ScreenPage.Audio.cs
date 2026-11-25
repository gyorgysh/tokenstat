// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Buffers.Binary;
using System.Runtime.InteropServices.WindowsRuntime;
using System.Threading.Channels;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Tokenstat.Design;
using Windows.Media.Core;
using Windows.Media.MediaProperties;
using Windows.Media.Playback;

namespace Tokenstat.Pages;

internal sealed partial class ScreenPage
{
    private readonly StackPanel _audioSlot = new();
    private ScreenAudio? _screenAudio;
    private bool _screenMuted;

    private void RefreshScreenAudio()
    {
        _audioSlot.Children.Clear();
        var toggle = Chrome.ToggleChip(L10n.Text("windows.screenpage.sound"), !_screenMuted, playing =>
        {
            _screenMuted = !playing;
            if (_screenMuted) ResetScreenAudio();
            RefreshScreenAudio();
            (_audioSlot.Children[0] as Button)?.Focus(FocusState.Programmatic);
            return Task.CompletedTask;
        });
        toggle.IsEnabled = !_closed && _sessionId is not null;
        _audioSlot.Children.Add(toggle);
    }

    private void PlayScreenAudio(string encoded)
    {
        if (_screenMuted || _closed || _accountGeneration != AppServices.AccountGeneration) return;
        var chunk = ScreenAudioChunk.Parse(encoded);
        if (chunk is null) return;
        try
        {
            if (_screenAudio is null || !_screenAudio.Accepts(chunk))
            {
                ResetScreenAudio();
                _screenAudio = new ScreenAudio(chunk.Rate, chunk.Channels);
            }
            _screenAudio.Enqueue(chunk);
        }
        catch (Exception ex)
        {
            System.Diagnostics.Debug.WriteLine($"Screen audio: {ex.Message}");
            ResetScreenAudio();
        }
    }

    private void ResetScreenAudio()
    {
        var previous = _screenAudio;
        _screenAudio = null;
        previous?.Dispose();
    }

    private sealed record ScreenAudioChunk(byte[] Data, uint Rate, uint Channels, uint Frames)
    {
        public const int HeaderSize = 16;

        public static ScreenAudioChunk? Parse(string encoded)
        {
            if (encoded.Length == 0 || encoded.Length > ((HeaderSize + 64 * 1024 + 2) / 3) * 4) return null;
            byte[] bytes;
            try { bytes = Convert.FromBase64String(encoded); }
            catch (FormatException) { return null; }
            if (bytes.Length <= HeaderSize || !bytes.AsSpan(0, 4).SequenceEqual("TAUD"u8) || bytes[4] != 1) return null;
            var channels = bytes[5];
            var rate = BinaryPrimitives.ReadUInt32BigEndian(bytes.AsSpan(8));
            var frames = BinaryPrimitives.ReadUInt32BigEndian(bytes.AsSpan(12));
            return channels is 1 or 2 && rate is >= 8000 and <= 192000 && frames > 0
                && HeaderSize + (long)frames * channels * 2 == bytes.Length && bytes.Length - HeaderSize <= 64 * 1024
                ? new ScreenAudioChunk(bytes, rate, channels, frames) : null;
        }
    }

    private sealed class ScreenAudio : IDisposable
    {
        private readonly Channel<ScreenAudioChunk> _queue = Channel.CreateBounded<ScreenAudioChunk>(
            new BoundedChannelOptions(4) { FullMode = BoundedChannelFullMode.DropOldest, SingleReader = true });
        private readonly MediaStreamSource _source;
        private readonly MediaPlayer _player;
        private readonly uint _rate;
        private readonly uint _channels;
        private long _frames;
        private int _disposed;

        public ScreenAudio(uint rate, uint channels)
        {
            _rate = rate;
            _channels = channels;
            _source = new MediaStreamSource(new AudioStreamDescriptor(AudioEncodingProperties.CreatePcm(rate, channels, 16)))
            {
                BufferTime = TimeSpan.Zero,
            };
            _source.SampleRequested += SampleRequested;
            _player = new MediaPlayer { RealTimePlayback = true };
            try
            {
                _player.CommandManager.IsEnabled = false;
                _player.Source = MediaSource.CreateFromMediaStreamSource(_source);
                _player.Play();
            }
            catch
            {
                Dispose();
                throw;
            }
        }

        public bool Accepts(ScreenAudioChunk chunk) => chunk.Rate == _rate && chunk.Channels == _channels;

        public void Enqueue(ScreenAudioChunk chunk) => _queue.Writer.TryWrite(chunk);

        private async void SampleRequested(MediaStreamSource source, MediaStreamSourceSampleRequestedEventArgs args)
        {
            var request = args.Request;
            var deferral = request.GetDeferral();
            try
            {
                var chunk = await _queue.Reader.ReadAsync().ConfigureAwait(false);
                if (Volatile.Read(ref _disposed) != 0) return;
                var start = TimeSpan.FromSeconds((double)_frames / _rate);
                _frames += chunk.Frames;
                var sample = MediaStreamSample.CreateFromBuffer(chunk.Data.AsBuffer(ScreenAudioChunk.HeaderSize,
                    chunk.Data.Length - ScreenAudioChunk.HeaderSize), start);
                sample.Duration = TimeSpan.FromSeconds((double)_frames / _rate) - start;
                request.Sample = sample;
            }
            catch (ChannelClosedException) { }
            catch (Exception ex) { System.Diagnostics.Debug.WriteLine($"Screen audio sample: {ex.Message}"); }
            finally { deferral.Complete(); }
        }

        public void Dispose()
        {
            if (Interlocked.Exchange(ref _disposed, 1) != 0) return;
            _queue.Writer.TryComplete();
            _source.SampleRequested -= SampleRequested;
            _player.Dispose();
        }
    }
}
