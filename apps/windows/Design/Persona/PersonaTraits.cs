// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using Windows.UI;

namespace Tokenstat.Design.Persona;

/// <summary>
/// The fixed features of one character, derived from its seed. Deterministic
/// and cheap: the same persona is the same creature on every launch with
/// nothing stored but the number. Nothing here changes with mood.
/// </summary>
internal sealed class PersonaTraits
{
    internal enum EyeShape
    {
        Round,
        Oval,
        Pixel,
    }

    internal enum MouthShape
    {
        Dot,
        Smile,
        Flat,
        Frown,
    }

    public Color Hue { get; }

    public int EyeCount { get; }

    public EyeShape Eye { get; }

    public MouthShape? Mouth { get; }

    public bool HasAntenna { get; }

    /// <summary>How wide this creature's mouth sits, as a multiplier.</summary>
    public double MouthWidth { get; }

    /// <summary>Stiffness multiplier. Below one is slime, above one is gel.</summary>
    public double Firmness { get; }

    /// <summary>A permanent radial offset per node: this creature's own dents.</summary>
    public double[] Lumps { get; }

    public PersonaTraits(ulong seed, int nodes = 14)
    {
        ulong bits = seed == 0 ? 0x9E3779B97F4A7C15ul : seed;
        ulong Next(ulong modulo)
        {
            bits ^= bits << 13;
            bits ^= bits >> 7;
            bits ^= bits << 17;
            return bits % modulo;
        }

        EyeCount = Next(10) switch
        {
            0 or 1 => 1,
            2 => 3,
            _ => 2,
        };
        Eye = Next(4) switch
        {
            0 => EyeShape.Round,
            1 => EyeShape.Pixel,
            _ => EyeShape.Oval,
        };
        Mouth = Next(5) switch
        {
            0 => MouthShape.Smile,
            1 => MouthShape.Flat,
            2 => MouthShape.Dot,
            _ => null,
        };
        HasAntenna = Next(3) == 0;
        MouthWidth = 0.78 + Next(9) * 0.06;
        Firmness = 0.78 + Next(9) * 0.055;
        // Two low harmonics rather than per-node noise. Noise reads as a
        // damaged circle, harmonics read as a shape somebody drew.
        double firstPhase = Next(360) * Math.PI / 180;
        double secondPhase = Next(360) * Math.PI / 180;
        double firstAmount = 0.35 + Next(100) / 100.0 * 0.45;
        double secondAmount = Next(100) / 100.0 * 0.30;
        Lumps = new double[nodes];
        for (int i = 0; i < nodes; i++)
        {
            double angle = i * 2 * Math.PI / nodes;
            Lumps[i] = Math.Sin(angle * 2 + firstPhase) * firstAmount
                + Math.Sin(angle * 3 + secondPhase) * secondAmount;
        }
        Hue = Theme.Accent.MixedWith(Theme.Secondary, Next(7) / 6.0);
    }
}

/// <summary>Colour helpers the persona renderer needs.</summary>
internal static class PersonaColor
{
    /// <summary>
    /// Blend towards another colour. Walks the accent-to-secondary arc so a
    /// persona's tint is always a colour this app already owns.
    /// </summary>
    public static Color MixedWith(this Color from, Color to, double amount)
    {
        double k = Math.Clamp(amount, 0, 1);
        return Color.FromArgb(
            (byte)(from.A + (to.A - from.A) * k),
            (byte)(from.R + (to.R - from.R) * k),
            (byte)(from.G + (to.G - from.G) * k),
            (byte)(from.B + (to.B - from.B) * k));
    }

    /// <summary>The colour with its alpha scaled. Values outside zero to one clamp.</summary>
    public static Color WithOpacity(this Color color, double opacity)
    {
        return Color.FromArgb(
            (byte)Math.Clamp(color.A * opacity, 0, 255),
            color.R,
            color.G,
            color.B);
    }
}

/// <summary>
/// A face for something that has no persona. Derived from the conversation's
/// own id, so it is that chat's face for as long as the chat exists. The same
/// FNV-1a as the Mac client, so both platforms draw the same family of faces.
/// </summary>
internal static class PersonaSeed
{
    public static ulong For(string identifier)
    {
        ulong hash = 0xCBF29CE484222325ul;
        foreach (byte b in System.Text.Encoding.UTF8.GetBytes(identifier))
        {
            unchecked
            {
                hash ^= b;
                hash *= 0x00000100000001B3ul;
            }
        }
        return hash | 1;
    }
}
