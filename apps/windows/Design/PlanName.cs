// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
namespace Tokenstat.Design;

/// <summary>
/// What a plan is called where a person reads it. The account server and the
/// stores keep the original keys (supporter, patron, legend) because product
/// ids depend on them, so a tier key is never capitalized into a label: it
/// goes through here.
/// </summary>
internal static class PlanName
{
    public static string Title(string tier) => tier.ToLowerInvariant() switch
    {
        "free" => L10n.Text("common.plan.free"),
        "supporter" => L10n.Text("common.plan.supporter"),
        "patron" => L10n.Text("common.plan.patron"),
        "legend" => L10n.Text("common.plan.legend"),
        "" => "",
        _ => char.ToUpperInvariant(tier[0]) + tier[1..],
    };
}
