// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using System.Reflection;

namespace Tokenstat.Design;

/// <summary>Static app metadata. Same facts as the Mac About window.</summary>
internal static class AppInfo
{
    public const string Product = "tokenstat";
    public const string Company = "pueev OÜ";
    public static readonly string Copyright = L10n.Text("windows.appinfo.pueev_o_all_rights_reserved.b1734f76");
    public const string WebsiteLabel = "tokenstat.ai";
    public const string Website = "https://tokenstat.ai/?ref=tokenstat_app";
    public const string Repository = "https://github.com/gyorgysh/tokenstat";
    public const string BundleId = "ai.tokenstat.tokenstat";
    public const string HostId = "ai.tokenstat.hostd";

    public static string Version =>
        Assembly.GetExecutingAssembly()
            .GetCustomAttribute<AssemblyInformationalVersionAttribute>()
            ?.InformationalVersion
            ?.Split('+')[0]
        ?? Assembly.GetExecutingAssembly().GetName().Version?.ToString()
        ?? "unknown";

    public static class Author
    {
        public const string Name = "Gyorgy";
        public static readonly string Role = L10n.Text("windows.appinfo.ai_native_product_engineer.e8e5f442");
        public const string Site = "https://gyorgy.sh/?ref=tokenstat_app";
        public const string SiteLabel = "gyorgy.sh";
        public const string Email = "mailto:gyorgy@pueev.com";
    }
}
