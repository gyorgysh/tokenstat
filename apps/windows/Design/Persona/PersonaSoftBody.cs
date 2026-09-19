// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

namespace Tokenstat.Design.Persona;

/// <summary>
/// The stage a persona lives on, in unit coordinates with y pointing down.
/// Everything is a fraction of the mark's frame, so one simulation serves a
/// small seat beside a message and a large hero from the same numbers.
/// </summary>
internal static class PersonaStage
{
    /// <summary>
    /// Where the body rests. Below it there is a shadow, above it a hop has
    /// room to travel without leaving the frame.
    /// </summary>
    public const double Floor = 0.95;

    /// <summary>
    /// The highest a node may go. A hard stop, not a spring: a bounce that
    /// escapes the frame is a bounce the transcript sees as a jump.
    /// </summary>
    public const double Ceiling = 0.02;

    public const double LeftRail = 0.02;

    public const double RightRail = 0.98;

    public const double CentreX = 0.5;

    /// <summary>
    /// Radius at rest, so the body fills a little under three quarters of the
    /// frame. What is left over is the headroom a hop, an antenna and a
    /// thought dot need.
    /// </summary>
    public const double RestRadius = 0.355;

    public static PPoint RestCentre => new(CentreX, Floor - RestRadius);
}

/// <summary>
/// Everything the simulation needs for one instant, produced by the mood.
/// A pose is a set of goals, never positions. A mood says "be this wide, pull
/// this way, push this hard" and the springs decide how the body gets there,
/// so every change of mood arrives with overshoot and settle already in it.
/// </summary>
internal struct PersonaDrive
{
    /// <summary>Downward acceleration. Zero floats, one falls at a cartoon rate.</summary>
    public double Gravity = 0.95;

    /// <summary>The rest ellipse, as multipliers on the radius. Squash and stretch.</summary>
    public PSize Stretch = new(1, 1);

    public double Radius = PersonaStage.RestRadius;

    /// <summary>
    /// How hard the body resists losing volume. This is what makes it read as
    /// a water balloon rather than a rubber band loop.
    /// </summary>
    public double Pressure = 44;

    public double RingStiffness = 210;

    /// <summary>
    /// How hard the body insists on being its own shape. High snaps back, low
    /// lets a squash linger.
    /// </summary>
    public double ShapeStiffness = 150;

    /// <summary>Velocity bleed per second. Low is sloppy slime, high is a firm gel.</summary>
    public double Damping = 3.4;

    /// <summary>A couple: the top half is pushed one way, the bottom half the other. A lean, not a rotation.</summary>
    public double Lean;

    /// <summary>Tangential churn. Thinking looks like something turning over inside.</summary>
    public double Swirl;

    /// <summary>Where the body wants to stand. Moving this is how a persona travels.</summary>
    public double AnchorX = PersonaStage.CentreX;

    public double AnchorPull = 7;

    public double Floor = PersonaStage.Floor;

    /// <summary>
    /// How much of its own weight the ground carries once the body is resting
    /// on it. One means all of it. Without this, gravity is paid for twice: it
    /// is what makes a landing squash, and also a steady downward pull on every
    /// node of a body that has already landed, which flattens a resting
    /// character. Cancelling it on contact keeps the two apart.
    /// </summary>
    public double Support = 1;

    public double Restitution = 0.34;

    public double Friction = 0.82;

    /// <summary>Per-node radial ripple. Deterministic, driven by WobblePhase.</summary>
    public double Wobble;

    public double WobblePhase;

    /// <summary>
    /// The second ripple channel, owned by the engine. Wobble is character, a
    /// mood's choice. This one is consequence: switched on by a hard landing
    /// and ringing down on its own.
    /// </summary>
    public double Jiggle;

    public double JigglePhase;

    public PersonaDrive()
    {
    }

    /// <summary>
    /// One set of forces on its way to becoming another. Every field is a
    /// number, so a mood change is a crossfade rather than a cut: for half a
    /// second the body is pulled by both moods at once and by neither
    /// completely.
    /// </summary>
    public static PersonaDrive Blend(PersonaDrive from, PersonaDrive to, double amount)
    {
        // Smoothstep, so the crossfade has no corner at either end. A linear
        // blend starts and stops abruptly and reads as a cut with a ramp.
        double t = Math.Clamp(amount, 0, 1);
        double k = t * t * (3 - 2 * t);
        double Mix(double a, double b) => a + (b - a) * k;
        var out_ = to;
        out_.Gravity = Mix(from.Gravity, to.Gravity);
        out_.Stretch = new PSize(Mix(from.Stretch.Width, to.Stretch.Width), Mix(from.Stretch.Height, to.Stretch.Height));
        out_.Radius = Mix(from.Radius, to.Radius);
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
        // Phases are clocks, not amounts. Blending two of them walks the
        // ripple backwards; the incoming one simply takes over.
        out_.WobblePhase = to.WobblePhase;
        out_.JigglePhase = to.JigglePhase;
        return out_;
    }
}

/// <summary>
/// A pressure soft body: a closed ring of point masses held out by internal
/// pressure and held in shape by springs. Fourteen masses give the thing
/// weight: it lands heavier when it falls further, it keeps ringing after a
/// hit, and a shove on one side travels round the rim.
/// </summary>
internal sealed class PersonaSoftBody
{
    internal struct Node
    {
        public PPoint P;
        public PVector V;
    }

    private readonly List<Node> _nodes;

    /// <summary>Scratch, kept around so a step allocates nothing.</summary>
    private readonly PVector[] _forces;

    /// <summary>
    /// Fixed per-node phase offsets, so the ripple runs round the rim rather
    /// than pulsing everywhere at once.
    /// </summary>
    private readonly double[] _ripple;

    /// <summary>
    /// How much of the body is resting on the ground, zero to one, eased so
    /// that touching down ramps the support in rather than snapping it on.
    /// </summary>
    private double _grounded;

    /// <summary>This creature's permanent dents, as a radial offset per node.</summary>
    private readonly double[] _lumps;

    /// <summary>
    /// The hardest a node hit the floor since the engine last looked, and
    /// where. Zero when nothing has landed.
    /// </summary>
    private double _impactSpeed;

    private double _impactX = PersonaStage.CentreX;

    public PersonaSoftBody(
        int count = 14,
        PPoint? centre = null,
        double radius = PersonaStage.RestRadius,
        double[]? lumps = null)
    {
        count = Math.Max(6, count - count % 2);
        var at = centre ?? PersonaStage.RestCentre;
        _nodes = new List<Node>(count);
        _ripple = new double[count];
        for (int i = 0; i < count; i++)
        {
            double angle = i * 2 * Math.PI / count;
            _nodes.Add(new Node
            {
                P = new PPoint(at.X + Math.Cos(angle) * radius, at.Y + Math.Sin(angle) * radius),
                V = PVector.Zero,
            });
            _ripple[i] = angle * 2;
        }
        _forces = new PVector[count];
        _lumps = lumps is { Length: var len } && len == count
            ? (double[])lumps.Clone()
            : new double[count];
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

    /// <summary>
    /// The body's travel, with its own ringing left out. Energy counts every
    /// node, so a slack blob quivering on the floor looks energetic to it. This
    /// is the mean velocity, where an internal wobble cancels itself and only
    /// the creature actually going somewhere survives.
    /// </summary>
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

    /// <summary>Sum of squared speeds. The sleep test.</summary>
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

    /// <summary>
    /// The landing since this was last called, and forget it. Consumed rather
    /// than read, so one landing pays for one splat however many steps the
    /// frame spent.
    /// </summary>
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

    /// <summary>
    /// Shove the whole body. Momentum is conserved, so a kick launches it and
    /// the jelly catches up: squash on the way out, stretch at the top.
    /// </summary>
    public void Impulse(PVector vector)
    {
        for (int i = 0; i < _nodes.Count; i++)
        {
            var node = _nodes[i];
            node.V += vector;
            _nodes[i] = node;
        }
    }

    /// <summary>
    /// A local hit, falling off with distance. What a landed ball does, and
    /// what makes a catch look like a catch rather than a jump.
    /// </summary>
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

    /// <summary>
    /// Push every node away from the centroid, or pull it in. A gasp, a
    /// flinch, the pop at the top of a celebration.
    /// </summary>
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

    /// <summary>Collapse toward the floor without moving sideways. The failure melt.</summary>
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

    /// <summary>
    /// Snap back to a clean ring. Used when motion is off and for the first
    /// frame, so a paused mark is a settled character rather than a spasm.
    /// </summary>
    public void Reset(PPoint? centre = null, PSize? stretch = null, double radius = PersonaStage.RestRadius)
    {
        var at = centre ?? PersonaStage.RestCentre;
        var st = stretch ?? new PSize(1, 1);
        _grounded = 1;
        for (int i = 0; i < _nodes.Count; i++)
        {
            double angle = i * 2 * Math.PI / _nodes.Count;
            _nodes[i] = new Node
            {
                P = new PPoint(
                    at.X + Math.Cos(angle) * radius * st.Width,
                    at.Y + Math.Sin(angle) * radius * st.Height),
                V = PVector.Zero,
            };
        }
    }

    /// <summary>
    /// One fixed step. Callers accumulate real time and run this at a fixed
    /// dt, because a spring integrated at a variable step is a spring that
    /// explodes the first time a frame is late.
    /// </summary>
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
        double target = Math.PI * drive.Radius * drive.Radius * drive.Stretch.Width * drive.Stretch.Height;
        // Clamped: an area that has briefly collapsed must not answer with a
        // force big enough to turn the body inside out.
        double pressure = drive.Pressure * Math.Clamp(target / Math.Max(area, 2e-4) - 1, -1.5, 3.0);

        double edgeRest = 2 * drive.Radius * Math.Sin(Math.PI / n);
        for (int i = 0; i < n; i++)
        {
            int next = (i + 1) % n;
            double dx = _nodes[next].P.X - _nodes[i].P.X;
            double dy = _nodes[next].P.Y - _nodes[i].P.Y;
            double length = Math.Max(Math.Sqrt(dx * dx + dy * dy), 1e-5);
            dx /= length;
            dy /= length;

            double spring = drive.RingStiffness * (length - edgeRest);
            _forces[i] += new PVector(spring * dx, spring * dy);
            _forces[next] += new PVector(-spring * dx, -spring * dy);

            // Outward normal for a ring wound in increasing angle with y down.
            double push = pressure * length * 0.5;
            _forces[i] += new PVector(dy * push, -dx * push);
            _forces[next] += new PVector(dy * push, -dx * push);
        }

        // Shape matching, and it is what holds the creature together. A ring
        // of springs has no bending stiffness: edge lengths and area can all
        // be satisfied by a teardrop, so gravity and a floor turn the blob
        // into a tent within a second and it stays there. This pulls each node
        // toward where it would be on the target ellipse, drawn around
        // wherever the body currently is. Because the goals are built on the
        // live centroid, they sum to zero and add no momentum: the body is
        // free to fall, bounce and travel, it just is not free to stop being
        // this shape.
        for (int i = 0; i < n; i++)
        {
            double angle = i * 2 * Math.PI / n;
            double reach = drive.Radius * (1 + _lumps[i] * 0.10);
            double goalX = centreX + Math.Cos(angle) * reach * drive.Stretch.Width;
            double goalY = centreY + Math.Sin(angle) * reach * drive.Stretch.Height;
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
                // The impact ring runs at its own faster rate and against the
                // ripple order, so a splat travels up the body rather than
                // beating with whatever the mood was already doing.
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
                        // Only a body that was in the air lands. A node of a
                        // resting creature grazing the floor is not an event.
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

    /// <summary>
    /// The silhouette ring, smoothed and mapped into pixels. One pass of
    /// Laplacian smoothing first: the simulation wants fourteen distinct
    /// masses, the eye wants a curve with no corners in it. The renderer draws
    /// Catmull-Rom through these, converted to Beziers.
    /// </summary>
    public PPoint[] Outline(double width, double height, double smoothing = 0.34)
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

    /// <summary>
    /// Where the body is right now, for anything drawn against it.
    /// </summary>
    public PersonaAnchors Anchors => new(Crown, Centroid, Bounds);

    /// <summary>
    /// Where the top of the head is, in unit space. The antenna roots here and
    /// a caught ball lands here, so both follow the squash.
    /// </summary>
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

/// <summary>
/// Where a character's body is, in unit space, for whatever is drawn against
/// it.
/// </summary>
internal readonly record struct PersonaAnchors(PPoint Crown, PPoint Centroid, PRect Bounds)
{
    /// <summary>
    /// Where a small thing is held: low and forward, straddling the bottom
    /// edge of the body. A blob has no arms, so a prop drawn wholly inside the
    /// silhouette reads as being in the creature rather than held by it.
    /// </summary>
    public PPoint Hands => new(Centroid.X, Bounds.MaxY - Bounds.Height * 0.20);

    /// <summary>
    /// Where the mouth is, near enough. Anything that comes out of the
    /// character rather than being held by it starts here.
    /// </summary>
    public PPoint Mouth => new(Centroid.X, Centroid.Y + Bounds.Height * 0.18);

    /// <summary>
    /// Where something is held up to be read: high enough to cover the body
    /// from just under the eyes down, so the character looks over the top of
    /// it.
    /// </summary>
    public PPoint Raised => new(Centroid.X, Centroid.Y + Bounds.Height * 0.26);
}
