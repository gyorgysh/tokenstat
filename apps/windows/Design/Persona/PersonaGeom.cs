// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

namespace Tokenstat.Design.Persona;

/// <summary>
/// A point in persona unit space, where the mark's frame is one by one and y
/// points down. Mirrors CGPoint in the Mac engine so the physics transcribes
/// line for line.
/// </summary>
internal readonly record struct PPoint(double X, double Y)
{
    public static PPoint operator +(PPoint p, PVector v) => new(p.X + v.X, p.Y + v.Y);

    public static PVector operator -(PPoint a, PPoint b) => new(a.X - b.X, a.Y - b.Y);
}

/// <summary>A velocity or a force. Mirrors CGVector.</summary>
internal readonly record struct PVector(double X, double Y)
{
    public static readonly PVector Zero = new(0, 0);

    public static PVector operator +(PVector a, PVector b) => new(a.X + b.X, a.Y + b.Y);

    public static PVector operator -(PVector a, PVector b) => new(a.X - b.X, a.Y - b.Y);

    public static PVector operator *(PVector v, double k) => new(v.X * k, v.Y * k);
}

/// <summary>A multiplier pair, for squash and stretch. Mirrors CGSize.</summary>
internal readonly record struct PSize(double Width, double Height);

/// <summary>A bounds rect in unit space. Mirrors CGRect.</summary>
internal readonly record struct PRect(double X, double Y, double Width, double Height)
{
    public double MinX => X;

    public double MinY => Y;

    public double MaxX => X + Width;

    public double MaxY => Y + Height;

    public double MidX => X + Width / 2;

    public double MidY => Y + Height / 2;
}
