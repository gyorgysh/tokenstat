// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

namespace Tokenstat.Design.Persona;

internal static class PersonaStage
{
    public const double Floor = 0.95;

    public const double Ceiling = 0.02;

    public const double LeftRail = 0.02;

    public const double RightRail = 0.98;

    public const double CentreX = 0.5;

    public const double RestRadius = 0.355;

    public static PPoint RestCentre => new(CentreX, Floor - RestRadius);
}

internal struct PersonaDrive
{
    public double Gravity = 0.95;

    public PSize Stretch = new(1, 1);

    public double Radius = PersonaStage.RestRadius;
    public double Roll;

    public double Pressure = 44;

    public double RingStiffness = 210;

    public double ShapeStiffness = 150;

    public double Damping = 3.4;

    public double Lean;

    public double Swirl;

    public double AnchorX = PersonaStage.CentreX;

    public double AnchorPull = 7;

    public double Floor = PersonaStage.Floor;

    public double Support = 1;

    public double Restitution = 0.34;

    public double Friction = 0.82;

    public double Wobble;

    public double WobblePhase;

    public double Jiggle;

    public double JigglePhase;

    public PersonaDrive()
    {
    }

    public static PersonaDrive Blend(PersonaDrive from, PersonaDrive to, double amount)
    {
        double t = Math.Clamp(amount, 0, 1);
        double k = t * t * (3 - 2 * t);
        double Mix(double a, double b) => a + (b - a) * k;
        var out_ = to;
        out_.Gravity = Mix(from.Gravity, to.Gravity);
        out_.Stretch = new PSize(Mix(from.Stretch.Width, to.Stretch.Width), Mix(from.Stretch.Height, to.Stretch.Height));
        out_.Radius = Mix(from.Radius, to.Radius);
        out_.Roll = Mix(from.Roll, to.Roll);
        out_.Pressure = Mix(from.Pressure, to.Pressure);
        out_.RingStiffness = Mix(from.RingStiffness, to.RingStiffness);
        out_.ShapeStiffness = Mix(from.ShapeStiffness, to.ShapeStiffness);
        out_.Damping = Mix(from.Damping, to.Damping);
        out_.Lean = Mix(from.Lean, to.Lean);
        out_.Swirl = Mix(from.Swirl, to.Swirl);
        out_.AnchorX = Mix(from.AnchorX, to.AnchorX);
        out_.AnchorPull = Mix(from.AnchorPull, to.AnchorPull);
        out_.Floor = Mix(from.Floor, to.Floor);
        out_.Support = Mix(from.Support, to.Support);
        out_.Restitution = Mix(from.Restitution, to.Restitution);
        out_.Friction = Mix(from.Friction, to.Friction);
        out_.Wobble = Mix(from.Wobble, to.Wobble);
        out_.Jiggle = Mix(from.Jiggle, to.Jiggle);
        out_.WobblePhase = to.WobblePhase;
        out_.JigglePhase = to.JigglePhase;
        return out_;
    }
}

internal sealed class PersonaSoftBody
{
    internal struct Node
    {
        public PPoint P;
        public PVector V;
    }

    private readonly List<Node> _nodes;

    private readonly PVector[] _forces;

    private readonly double[] _ripple;
    private readonly (double X, double Y)[] _shapeBasis;
    private readonly double[] _restEdges;
    private readonly double _restArea;
    private readonly PPoint _restOffset;
    public double RestBottom { get; }

    private double _grounded;

    private readonly double[] _lumps;

    private double _impactSpeed;

    private double _impactX = PersonaStage.CentreX;

    public PersonaSoftBody(
        int count = 20,
        PPoint? centre = null,
        double radius = PersonaStage.RestRadius,
        double[]? lumps = null)
    {
        count = Math.Max(6, count - count % 2);
        var at = centre ?? PersonaStage.RestCentre;
        _nodes = new List<Node>(count);
        _ripple = new double[count];
        _shapeBasis = new (double, double)[count];
        _restEdges = new double[count];
        for (int i = 0; i < count; i++)
        {
            double angle = i * 2 * Math.PI / count;
            _nodes.Add(new Node
            {
                P = new PPoint(at.X + Math.Cos(angle) * radius, at.Y + Math.Sin(angle) * radius),
                V = PVector.Zero,
            });
            _ripple[i] = angle * 2;
            _shapeBasis[i] = (Math.Cos(angle), Math.Sin(angle));
        }
        _forces = new PVector[count];
        _lumps = lumps is { Length: var len } && len == count
            ? (double[])lumps.Clone()
            : new double[count];
        double area = 0, sumX = 0, sumY = 0;
        for (int i = 0; i < count; i++)
        {
            int next = (i + 1) % count;
            double x = _shapeBasis[i].X * (1 + _lumps[i] * 0.10);
            double y = _shapeBasis[i].Y * (1 + _lumps[i] * 0.10);
            double nx = _shapeBasis[next].X * (1 + _lumps[next] * 0.10);
            double ny = _shapeBasis[next].Y * (1 + _lumps[next] * 0.10);
            _restEdges[i] = Math.Sqrt((nx - x) * (nx - x) + (ny - y) * (ny - y));
            area += x * ny - nx * y;
            sumX += x; sumY += y;
        }
        _restArea = Math.Abs(area) * 0.5;
        _restOffset = new PPoint(sumX / count, sumY / count);
        RestBottom = Enumerable.Range(0, count).Max(i => _shapeBasis[i].Y * (1 + _lumps[i] * 0.10)) - _restOffset.Y;
    }

    public int Count => _nodes.Count;

    public PPoint Centroid
    {
        get
        {
            double x = 0;
            double y = 0;
            foreach (var node in _nodes)
            {
                x += node.P.X;
                y += node.P.Y;
            }
            double inverse = 1.0 / _nodes.Count;
            return new PPoint(x * inverse, y * inverse);
        }
    }

    public PVector Momentum
    {
        get
        {
            double dx = 0;
            double dy = 0;
            foreach (var node in _nodes)
            {
                dx += node.V.X;
                dy += node.V.Y;
            }
            double inverse = 1.0 / _nodes.Count;
            return new PVector(dx * inverse, dy * inverse);
        }
    }

    public double Energy
    {
        get
        {
            double total = 0;
            foreach (var node in _nodes)
            {
                total += node.V.X * node.V.X + node.V.Y * node.V.Y;
            }
            return total;
        }
    }

    public (double Speed, double X)? TakeImpact()
    {
        if (_impactSpeed <= 0)
        {
            return null;
        }
        var hit = (_impactSpeed, _impactX);
        _impactSpeed = 0;
        return hit;
    }

    public PRect Bounds
    {
        get
        {
            double minX = double.MaxValue;
            double minY = double.MaxValue;
            double maxX = double.MinValue;
            double maxY = double.MinValue;
            foreach (var node in _nodes)
            {
                minX = Math.Min(minX, node.P.X);
                minY = Math.Min(minY, node.P.Y);
                maxX = Math.Max(maxX, node.P.X);
                maxY = Math.Max(maxY, node.P.Y);
            }
            return new PRect(minX, minY, maxX - minX, maxY - minY);
        }
    }

    public void Impulse(PVector vector)
    {
        for (int i = 0; i < _nodes.Count; i++)
        {
            var node = _nodes[i];
            node.V += vector;
            _nodes[i] = node;
        }
    }

    public void Poke(PPoint point, double strength, double reach = 0.22)
    {
        for (int i = 0; i < _nodes.Count; i++)
        {
            double dx = _nodes[i].P.X - point.X;
            double dy = _nodes[i].P.Y - point.Y;
            double distance = Math.Sqrt(dx * dx + dy * dy);
            if (distance >= reach)
            {
                continue;
            }
            double falloff = 1 - distance / reach;
            double scale = strength * falloff * falloff;
            double inverse = 1 / Math.Max(distance, 1e-4);
            var node = _nodes[i];
            node.V = new PVector(node.V.X + dx * inverse * scale, node.V.Y + dy * inverse * scale);
            _nodes[i] = node;
        }
    }

    public void Pulse(double strength)
    {
        var centre = Centroid;
        for (int i = 0; i < _nodes.Count; i++)
        {
            double dx = _nodes[i].P.X - centre.X;
            double dy = _nodes[i].P.Y - centre.Y;
            double distance = Math.Max(Math.Sqrt(dx * dx + dy * dy), 1e-4);
            var node = _nodes[i];
            node.V = new PVector(node.V.X + dx / distance * strength, node.V.Y + dy / distance * strength);
            _nodes[i] = node;
        }
    }

    public void Slump(double strength)
    {
        var centre = Centroid;
        for (int i = 0; i < _nodes.Count; i++)
        {
            var node = _nodes[i];
            double above = centre.Y - node.P.Y;
            node.V = new PVector(
                node.V.X + (node.P.X - centre.X) * strength * 0.6,
                node.V.Y + Math.Max(above, 0) * strength);
            _nodes[i] = node;
        }
    }

    public void Reset(PPoint? centre = null, PSize? stretch = null, double radius = PersonaStage.RestRadius)
    {
        var at = centre ?? PersonaStage.RestCentre;
        var st = stretch ?? new PSize(1, 1);
        _grounded = 1;
        for (int i = 0; i < _nodes.Count; i++)
        {
            double angle = i * 2 * Math.PI / _nodes.Count;
            double reach = radius * (1 + _lumps[i] * 0.10);
            _nodes[i] = new Node
            {
                P = new PPoint(
                    at.X + (Math.Cos(angle) * reach - _restOffset.X * radius) * st.Width,
                    at.Y + (Math.Sin(angle) * reach - _restOffset.Y * radius) * st.Height),
                V = PVector.Zero,
            };
        }
    }

    public void Step(double dt, PersonaDrive drive)
    {
        int n = _nodes.Count;
        if (n <= 3)
        {
            return;
        }

        double weight = drive.Gravity * (1 - _grounded * drive.Support);
        for (int i = 0; i < n; i++)
        {
            _forces[i] = new PVector(0, weight);
        }

        double centreX = 0;
        double centreY = 0;
        foreach (var node in _nodes)
        {
            centreX += node.P.X;
            centreY += node.P.Y;
        }
        centreX /= n;
        centreY /= n;

        double doubleArea = 0;
        for (int i = 0; i < n; i++)
        {
            var a = _nodes[i].P;
            var b = _nodes[(i + 1) % n].P;
            doubleArea += a.X * b.Y - b.X * a.Y;
        }
        double area = Math.Abs(doubleArea) * 0.5;
        double target = _restArea * drive.Radius * drive.Radius * drive.Stretch.Width * drive.Stretch.Height;
        double pressure = drive.Pressure * Math.Clamp(target / Math.Max(area, 2e-4) - 1, -1.5, 3.0);

        for (int i = 0; i < n; i++)
        {
            int next = (i + 1) % n;
            double dx = _nodes[next].P.X - _nodes[i].P.X;
            double dy = _nodes[next].P.Y - _nodes[i].P.Y;
            double length = Math.Max(Math.Sqrt(dx * dx + dy * dy), 1e-5);
            dx /= length;
            dy /= length;

            double spring = drive.RingStiffness * (length - _restEdges[i] * drive.Radius);
            _forces[i] += new PVector(spring * dx, spring * dy);
            _forces[next] += new PVector(-spring * dx, -spring * dy);

            double push = pressure * length * 0.5;
            _forces[i] += new PVector(dy * push, -dx * push);
            _forces[next] += new PVector(dy * push, -dx * push);
        }

        double rollSin = Math.Sin(drive.Roll), rollCos = Math.Cos(drive.Roll);
        double offsetX = (_restOffset.X * rollCos - _restOffset.Y * rollSin) * drive.Radius;
        double offsetY = (_restOffset.Y * rollCos + _restOffset.X * rollSin) * drive.Radius;
        for (int i = 0; i < n; i++)
        {
            var basis = _shapeBasis[i];
            double x = basis.X * rollCos - basis.Y * rollSin;
            double y = basis.Y * rollCos + basis.X * rollSin;
            double reach = drive.Radius * (1 + _lumps[i] * 0.10);
            double goalX = centreX + (x * reach - offsetX) * drive.Stretch.Width;
            double goalY = centreY + (y * reach - offsetY) * drive.Stretch.Height;
            _forces[i] += new PVector(
                (goalX - _nodes[i].P.X) * drive.ShapeStiffness,
                (goalY - _nodes[i].P.Y) * drive.ShapeStiffness);
        }

        double anchor = (drive.AnchorX - centreX) * drive.AnchorPull;
        double inverseRadius = 1 / Math.Max(drive.Radius, 1e-4);
        for (int i = 0; i < n; i++)
        {
            _forces[i] += new PVector(anchor, 0);

            if (drive.Lean != 0)
            {
                _forces[i] += new PVector(drive.Lean * (centreY - _nodes[i].P.Y) * inverseRadius, 0);
            }

            double dx = _nodes[i].P.X - centreX;
            double dy = _nodes[i].P.Y - centreY;
            if (drive.Swirl != 0)
            {
                _forces[i] += new PVector(-dy * drive.Swirl, dx * drive.Swirl);
            }
            if (drive.Wobble != 0 || drive.Jiggle != 0)
            {
                double distance = Math.Max(Math.Sqrt(dx * dx + dy * dy), 1e-4);
                double amount = drive.Wobble * Math.Sin(drive.WobblePhase * 2 * Math.PI + _ripple[i]);
                amount += drive.Jiggle * Math.Sin(drive.JigglePhase * 2 * Math.PI - _ripple[i] * 1.5);
                _forces[i] += new PVector(dx / distance * amount, dy / distance * amount);
            }
        }

        double damp = Math.Max(0, 1 - drive.Damping * dt);
        int contacts = 0;
        for (int i = 0; i < n; i++)
        {
            var node = _nodes[i];
            node.V = new PVector(
                (node.V.X + _forces[i].X * dt) * damp,
                (node.V.Y + _forces[i].Y * dt) * damp);
            node.P = new PPoint(node.P.X + node.V.X * dt, node.P.Y + node.V.Y * dt);

            if (node.P.Y > drive.Floor - 0.004)
            {
                contacts += 1;
                if (node.P.Y > drive.Floor)
                {
                    node.P = new PPoint(node.P.X, drive.Floor);
                    if (node.V.Y > 0)
                    {
                        if (_grounded < 0.55 && node.V.Y > _impactSpeed)
                        {
                            _impactSpeed = node.V.Y;
                            _impactX = node.P.X;
                        }
                        node.V = new PVector(node.V.X, -node.V.Y * drive.Restitution);
                    }
                    node.V = new PVector(node.V.X * drive.Friction, node.V.Y);
                }
            }
            if (node.P.Y < PersonaStage.Ceiling)
            {
                node.P = new PPoint(node.P.X, PersonaStage.Ceiling);
                if (node.V.Y < 0)
                {
                    node.V = new PVector(node.V.X, -node.V.Y * 0.25);
                }
            }
            if (node.P.X < PersonaStage.LeftRail)
            {
                node.P = new PPoint(PersonaStage.LeftRail, node.P.Y);
                if (node.V.X < 0)
                {
                    node.V = new PVector(-node.V.X * 0.4, node.V.Y);
                }
            }
            if (node.P.X > PersonaStage.RightRail)
            {
                node.P = new PPoint(PersonaStage.RightRail, node.P.Y);
                if (node.V.X > 0)
                {
                    node.V = new PVector(-node.V.X * 0.4, node.V.Y);
                }
            }
            _nodes[i] = node;
        }

        double resting = Math.Min(1, contacts / 3.0);
        _grounded += (resting - _grounded) * Math.Min(1, dt * 22);
    }

    public PPoint[] Outline(double width, double height, double smoothing = 0.18)
    {
        int n = _nodes.Count;
        var points = new PPoint[n];
        for (int i = 0; i < n; i++)
        {
            var previous = _nodes[(i + n - 1) % n].P;
            var current = _nodes[i].P;
            var next = _nodes[(i + 1) % n].P;
            double x = current.X + ((previous.X + next.X) * 0.5 - current.X) * smoothing;
            double y = current.Y + ((previous.Y + next.Y) * 0.5 - current.Y) * smoothing;
            points[i] = new PPoint(x * width, y * height);
        }
        return points;
    }

    public PersonaAnchors Anchors => new(Crown, Centroid, Bounds);

    public PPoint Crown
    {
        get
        {
            var best = _nodes[0].P;
            foreach (var node in _nodes)
            {
                if (node.P.Y < best.Y)
                {
                    best = node.P;
                }
            }
            return best;
        }
    }
}

internal readonly record struct PersonaAnchors(PPoint Crown, PPoint Centroid, PRect Bounds)
{
    public PPoint Hands => new(Centroid.X, Bounds.MaxY - Bounds.Height * 0.20);

    public PPoint Mouth => new(Centroid.X, Centroid.Y + Bounds.Height * 0.18);

    public PPoint Raised => new(Centroid.X, Centroid.Y + Bounds.Height * 0.26);
}
