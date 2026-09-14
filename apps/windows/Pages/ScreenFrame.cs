// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

namespace Tokenstat.Pages;

/// <summary>
/// One video frame off the screen wire, parsed exactly like the Apple
/// ScreenEncodedFrame: the TSCR envelope carries version 1 and kind video,
/// and the payload is Annex-B H.264. ToAvcc converts the payload to
/// length-prefixed samples, keeping picture units (1-5) and the in-band
/// parameter sets (7-8) the Windows decoder needs, and dropping SEI and
/// AUD units the same way the Apple decoder leaves them out of its own
/// samples. Only four-byte start codes are split, matching the Apple
/// annexBUnits.
/// </summary>
internal sealed class ScreenFrame
{
    public ulong Sequence { get; }

    public int Width { get; }

    public int Height { get; }

    public bool Keyframe { get; }

    public byte[] Payload { get; }

    private ScreenFrame(ulong sequence, int width, int height, bool keyframe, byte[] payload)
    {
        Sequence = sequence;
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
        if (bytes.Length != 32 + payloadLength)
        {
            return null;
        }
        var payload = new byte[payloadLength];
        Array.Copy(bytes, 32, payload, 0, (int)payloadLength);
        return new ScreenFrame(sequence, width, height, keyframe, payload);
    }

    /// <summary>
    /// Stills from older hosts arrive as plain JPEG, with or without the
    /// envelope around them.
    /// </summary>
    public static bool LooksLikeJpeg(byte[] bytes) =>
        bytes.Length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xD8;

    public byte[] ToAvcc()
    {
        var kept = new List<byte[]>();
        var total = 0;
        foreach (var unit in SplitAnnexB(Payload))
        {
            if (unit.Length == 0)
            {
                continue;
            }
            var nal = unit[0] & 0x1F;
            var picture = nal >= 1 && nal <= 5;
            if (!picture && nal != 7 && nal != 8)
            {
                continue;
            }
            kept.Add(unit);
            total += 4 + unit.Length;
        }
        var avcc = new byte[total];
        var pos = 0;
        foreach (var unit in kept)
        {
            avcc[pos++] = (byte)(unit.Length >> 24);
            avcc[pos++] = (byte)(unit.Length >> 16);
            avcc[pos++] = (byte)(unit.Length >> 8);
            avcc[pos++] = (byte)unit.Length;
            Array.Copy(unit, 0, avcc, pos, unit.Length);
            pos += unit.Length;
        }
        return avcc;
    }

    private static List<byte[]> SplitAnnexB(byte[] payload)
    {
        var starts = new List<int>();
        for (var i = 0; i + 3 < payload.Length; i++)
        {
            if (payload[i] == 0 && payload[i + 1] == 0
                && payload[i + 2] == 0 && payload[i + 3] == 1)
            {
                starts.Add(i + 4);
            }
        }
        var units = new List<byte[]>();
        for (var k = 0; k < starts.Count; k++)
        {
            var start = starts[k];
            var end = k + 1 < starts.Count ? starts[k + 1] - 4 : payload.Length;
            if (end <= start)
            {
                continue;
            }
            var unit = new byte[end - start];
            Array.Copy(payload, start, unit, 0, unit.Length);
            units.Add(unit);
        }
        return units;
    }
}
