// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
namespace Tokenstat.Design;

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
