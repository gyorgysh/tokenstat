// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
namespace Tokenstat.Pages;

internal static class ChatImagePolicy
{
    internal const long RemoteAutomaticMaximumBytes = 5L * 1024 * 1024;
    internal static long DownloadLimit(bool userInitiated, bool remote, long fileMaximumBytes) =>
        userInitiated || !remote ? fileMaximumBytes : Math.Min(RemoteAutomaticMaximumBytes, fileMaximumBytes);
}
