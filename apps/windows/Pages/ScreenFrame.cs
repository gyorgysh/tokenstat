// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

namespace Tokenstat.Pages;

/// <summary>Version-one TSCR video envelope with an unchanged Annex-B H.264 payload.</summary>
internal sealed class ScreenFrame
{
    public ulong Sequence { get; }

    public ulong TimestampMicroseconds { get; }

    public int Width { get; }

    public int Height { get; }

    public bool Keyframe { get; }

    public byte[] Payload { get; }

    private ScreenFrame(ulong sequence, ulong timestamp, int width, int height, bool keyframe, byte[] payload)
    {
        Sequence = sequence;
        TimestampMicroseconds = timestamp;
        Width = width;
        Height = height;
        Keyframe = keyframe;
        Payload = payload;
    }

    public static ScreenFrame? Parse(byte[] bytes)
    {
        if (bytes.Length < 32)
        {
            return null;
        }
        if (bytes[0] != (byte)'T' || bytes[1] != (byte)'S'
            || bytes[2] != (byte)'C' || bytes[3] != (byte)'R')
        {
            return null;
        }
        if (bytes[4] != 1 || bytes[5] != 1)
        {
            return null;
        }
        var keyframe = (bytes[6] & 1) == 1;
        ulong sequence = ((ulong)bytes[8] << 56)
            | ((ulong)bytes[9] << 48)
            | ((ulong)bytes[10] << 40)
            | ((ulong)bytes[11] << 32)
            | ((ulong)bytes[12] << 24)
            | ((ulong)bytes[13] << 16)
            | ((ulong)bytes[14] << 8)
            | bytes[15];
        var width = (bytes[24] << 8) | bytes[25];
        var height = (bytes[26] << 8) | bytes[27];
        var payloadLength = ((uint)bytes[28] << 24)
            | ((uint)bytes[29] << 16)
            | ((uint)bytes[30] << 8)
            | bytes[31];
        if ((ulong)bytes.Length != 32UL + payloadLength || width == 0 || height == 0)
        {
            return null;
        }
        var payload = new byte[payloadLength];
        Array.Copy(bytes, 32, payload, 0, (int)payloadLength);
        return new ScreenFrame(sequence, System.Buffers.Binary.BinaryPrimitives.ReadUInt64BigEndian(bytes.AsSpan(16, 8)), width, height, keyframe, payload);
    }

    /// <summary>
    /// Stills from older hosts arrive as plain JPEG, with or without the
    /// envelope around them.
    /// </summary>
    public static bool LooksLikeJpeg(byte[] bytes) =>
        bytes.Length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xD8;

}
