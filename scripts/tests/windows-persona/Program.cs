// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using Tokenstat.Design.Persona;

SceneTests.Run();

for (int variant = 0; variant < 12; variant++)
{
    var body = new PersonaSoftBody();
    var drive = new PersonaDrive { ShapeStiffness = 150 * (0.7 + variant * 0.05) };
    for (int frame = 0; frame < 7200; frame++)
    {
        double time = frame / 120.0;
        drive.Roll = time * 1.25;
        if (frame % 360 == 0) body.Impulse(new PVector(0.1, -0.5));
        body.Step(1.0 / 120, drive);
        var bounds = body.Bounds;
        if (!double.IsFinite(bounds.Width) || !double.IsFinite(bounds.Height)
            || bounds.Width < 0.1 || bounds.Height < 0.1
            || bounds.MinX < PersonaStage.LeftRail || bounds.MaxX > PersonaStage.RightRail
            || bounds.MinY < PersonaStage.Ceiling || bounds.MaxY > PersonaStage.Floor)
            throw new Exception($"Unstable rolling variant {variant}, frame {frame}");
    }
}
Console.WriteLine("Windows persona: 12 variants × 60 seconds of bounded rolling pass");

foreach (ulong seed in new ulong[] { 0, 1, 3, 5, 7, 997, ulong.MaxValue })
{
    var engine = new PersonaEngine(seed);
    var restBody = new PersonaSoftBody(lumps: engine.Traits.Lumps);
    restBody.Reset(new PPoint(0.5, 0.48), radius: 0.28);
    var restPose = restBody.Outline(1, 1);
    var restDrive = new PersonaDrive { Gravity = 0, Radius = 0.28 };
    for (int frame = 0; frame < 2400; frame++) restBody.Step(1.0 / 120, restDrive);
    var settledPose = restBody.Outline(1, 1);
    for (int i = 0; i < restPose.Length; i++)
        if (Math.Abs(restPose[i].X - settledPose[i].X) + Math.Abs(restPose[i].Y - settledPose[i].Y) > 1e-5)
            throw new Exception("Fixed plush silhouette drifted or rounded into another shape");
    double time = 0;
    engine.AdvanceTo(time, PersonaMood.Idle, true);
    foreach (var from in Enum.GetValues<PersonaMood>())
    foreach (var to in Enum.GetValues<PersonaMood>())
    {
        engine.AdvanceTo(time, from, true);
        for (int frame = 0; frame < 45; frame++)
        {
            time += 1.0 / 60;
            engine.AdvanceTo(time, to, true);
            var bounds = engine.Body.Bounds;
            if (!double.IsFinite(engine.Roll) || !double.IsFinite(engine.Yaw)
                || bounds.Width < 0.1 || bounds.Height < 0.1
                || bounds.MinX < PersonaStage.LeftRail || bounds.MaxX > PersonaStage.RightRail
                || bounds.MinY < PersonaStage.Ceiling || bounds.MaxY > PersonaStage.Floor)
                throw new Exception($"Unstable transition {from} -> {to}");
        }
    }
    var frozen = engine.Body.Bounds;
    engine.SuspendClock();
    engine.AdvanceTo(time + 3600, engine.Mood, true);
    if (engine.Body.Bounds != frozen) throw new Exception("Suspension caught up");
    engine.AdvanceTo(time + 3601, PersonaMood.Idle, false);
    var settled = engine.Body.Bounds;
    engine.AdvanceTo(time + 3602, PersonaMood.Idle, false);
    if (engine.Roll != 0 || engine.Yaw != 0 || engine.Body.Bounds != settled)
        throw new Exception("Reduced motion did not stay still");
}
Console.WriteLine("Windows persona engine: all mood pairs across all four plush shapes, suspension and Reduce Motion pass");
