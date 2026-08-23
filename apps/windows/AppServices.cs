// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using Tokenstat.Host;
using Tokenstat.Install;

namespace Tokenstat;

internal static class AppServices
{
    public static HostClient Host { get; } = new();
    public static AppUpdateModel Update { get; } = new();
}
