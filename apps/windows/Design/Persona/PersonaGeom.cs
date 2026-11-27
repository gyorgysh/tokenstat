// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

namespace Tokenstat.Design.Persona;

internal readonly record struct PPoint(double X, double Y)
{
    public static PPoint operator +(PPoint p, PVector v) => new(p.X + v.X, p.Y + v.Y);

    public static PVector operator -(PPoint a, PPoint b) => new(a.X - b.X, a.Y - b.Y);
}

internal readonly record struct PVector(double X, double Y)
{
    public static readonly PVector Zero = new(0, 0);

    public static PVector operator +(PVector a, PVector b) => new(a.X + b.X, a.Y + b.Y);

    public static PVector operator -(PVector a, PVector b) => new(a.X - b.X, a.Y - b.Y);

    public static PVector operator *(PVector v, double k) => new(v.X * k, v.Y * k);
}

internal readonly record struct PSize(double Width, double Height);

internal readonly record struct PRect(double X, double Y, double Width, double Height)
{
    public double MinX => X;

    public double MinY => Y;

    public double MaxX => X + Width;

    public double MaxY => Y + Height;

    public double MidX => X + Width / 2;

    public double MidY => Y + Height / 2;
}
