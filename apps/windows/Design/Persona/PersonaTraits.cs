// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using Windows.UI;

namespace Tokenstat.Design.Persona;

internal sealed class PersonaTraits
{
    internal enum BodyShape { Ball, Star, Heart, Tortilla }
    public BodyShape Shape { get; }

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

    public double MouthWidth { get; }

    public double Firmness { get; }

    public double[] Lumps { get; }

    private static readonly (double X, double Y)[] HeartOutline = Enumerable.Range(0, 64).Select(i =>
    {
        double t = i * 2 * Math.PI / 64;
        return (16 * Math.Pow(Math.Sin(t), 3) / 17,
            -(13 * Math.Cos(t) - 5 * Math.Cos(2 * t) - 2 * Math.Cos(3 * t) - Math.Cos(4 * t)) / 17);
    }).ToArray();

    private static double HeartRadius(double angle)
    {
        double dx = Math.Cos(angle), dy = Math.Sin(angle), radius = 1;
        for (int i = 0; i < HeartOutline.Length; i++)
        {
            var p = HeartOutline[i]; var q = HeartOutline[(i + 1) % HeartOutline.Length];
            double ex = q.X - p.X, ey = q.Y - p.Y;
            double cross = dx * ey - dy * ex;
            if (Math.Abs(cross) < 1e-8) continue;
            double u = (p.X * dy - p.Y * dx) / cross;
            double r = (p.X * ey - p.Y * ex) / cross;
            if (u >= 0 && u <= 1 && r > 0) radius = Math.Min(radius, r);
        }
        return Math.Max(0.42, radius);
    }

    public PersonaTraits(ulong seed, int nodes = 20)
    {
        Shape = (BodyShape)((seed >> 1) % 4);
        ulong bits = seed == 0 ? 0x9E3779B97F4A7C15ul : seed;
        ulong Next(ulong modulo)
        {
            bits ^= bits << 13;
            bits ^= bits >> 7;
            bits ^= bits << 17;
            return bits % modulo;
        }

        _ = Next(10);
        EyeCount = 2;
        Eye = Next(4) == 0 ? EyeShape.Round : EyeShape.Oval;
        _ = Next(5);
        Mouth = MouthShape.Smile;
        _ = Next(3);
        HasAntenna = false;
        MouthWidth = 0.72 + Next(9) * 0.035;
        Firmness = 0.95 + Next(9) * 0.03;
        double firstPhase = Next(360) * Math.PI / 180;
        double secondPhase = Next(360) * Math.PI / 180;
        double firstAmount = 0.10 + Next(100) / 100.0 * 0.15;
        double secondAmount = 0.04 + Next(100) / 100.0 * 0.07;
        Lumps = new double[nodes];
        for (int i = 0; i < nodes; i++)
        {
            double angle = i * 2 * Math.PI / nodes;
            double silhouette = Shape switch
            {
                BodyShape.Star => -Math.Sin(5 * angle) * 0.24,
                BodyShape.Heart => HeartRadius(angle) - 1,
                BodyShape.Tortilla => (0.6 * Math.Cos(2 * angle) + 0.35 * Math.Sin(angle)) * 0.34,
                _ => 0,
            };
            double softness = Math.Sin(angle * 2 + firstPhase) * firstAmount
                + Math.Sin(angle * 3 + secondPhase) * secondAmount;
            Lumps[i] = silhouette * 10 + softness * 0.25;
        }
        Hue = Theme.Accent.MixedWith(Theme.Secondary, Next(7) / 6.0);
    }
}

internal static class PersonaColor
{
    public static Color MixedWith(this Color from, Color to, double amount)
    {
        double k = Math.Clamp(amount, 0, 1);
        return Color.FromArgb(
            (byte)(from.A + (to.A - from.A) * k),
            (byte)(from.R + (to.R - from.R) * k),
            (byte)(from.G + (to.G - from.G) * k),
            (byte)(from.B + (to.B - from.B) * k));
    }

    public static Color WithOpacity(this Color color, double opacity)
    {
        return Color.FromArgb(
            (byte)Math.Clamp(color.A * opacity, 0, 255),
            color.R,
            color.G,
            color.B);
    }
}

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
