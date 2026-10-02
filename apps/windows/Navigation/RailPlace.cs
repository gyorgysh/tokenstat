// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
namespace Tokenstat.Navigation;

/// <summary>Machine-wide places, in the same order as the macOS rail.</summary>
internal enum RailPlace { Home, Projects, Tasks, Notes, Automations, Insights, Devices, Ssh }

internal static class RailPlaces
{
    public static RailPlace? Of(string? route)
    {
        if (route is null) return null;
        if (route.StartsWith("ws:", StringComparison.Ordinal)
            || route.StartsWith("wsterm:", StringComparison.Ordinal)
            || route.StartsWith("wschat:", StringComparison.Ordinal)
            || route == "workspaces:all") return RailPlace.Projects;
        if (route.StartsWith("ssh:", StringComparison.Ordinal)
            || route.StartsWith("sshterm:", StringComparison.Ordinal)) return RailPlace.Ssh;
        return route switch
        {
            "global:Home" => RailPlace.Home,
            "global:Todo" => RailPlace.Tasks,
            "global:Notes" => RailPlace.Notes,
            "global:Automations" or "global:Workflows" => RailPlace.Automations,
            "global:Insights" => RailPlace.Insights,
            "global:Machines" => RailPlace.Devices,
            "global:Ssh" => RailPlace.Ssh,
            _ => null,
        };
    }

    public static string Route(this RailPlace place) => place switch
    {
        RailPlace.Projects => "workspaces:all",
        RailPlace.Tasks => "global:Todo",
        RailPlace.Devices => "global:Machines",
        RailPlace.Ssh => "ssh:Hosts",
        _ => "global:" + place,
    };
}
