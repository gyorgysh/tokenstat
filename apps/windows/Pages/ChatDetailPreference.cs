// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE.

namespace Tokenstat.Pages;

/// <summary>
/// The chosen transcript detail level, one for every chat on this computer,
/// like the Mac's <c>chat.detailLevel</c> default. Compact until somebody picks.
///
/// A plain file, not LocalSettings: this app is unpackaged, and
/// ApplicationData.Current throws there.
/// </summary>
internal static class ChatDetailPreference
{
    private static ChatDetail? _level;

    private static string FilePath => InAppData("chat-detail-level.txt");

    /// <summary>
    /// Where the level lived while "minimal" meant a line per step and
    /// "compact" a line per stretch of work. Those two names swapped.
    /// </summary>
    private static string PreviousFilePath => InAppData("chat-detail.txt");

    private static string InAppData(string name) => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "tokenstat",
        name);

    public static ChatDetail Level
    {
        get => _level ??= Load();
        set
        {
            _level = value;
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
                File.WriteAllText(FilePath, value.ToString().ToLowerInvariant());
            }
            catch
            {
                // Remembering is a courtesy. This session keeps the choice.
            }
        }
    }

    private static ChatDetail Load()
    {
        try
        {
            if (File.Exists(FilePath)
                && Enum.TryParse<ChatDetail>(File.ReadAllText(FilePath).Trim(), ignoreCase: true, out var level)
                && Enum.IsDefined(level))
            {
                return level;
            }
            if (File.Exists(PreviousFilePath) && Renamed(File.ReadAllText(PreviousFilePath)) is { } moved)
            {
                Level = moved;
                return moved;
            }
        }
        catch
        {
            // A damaged file only costs the remembered level.
        }
        return ChatDetail.Compact;
    }

    /// <summary>
    /// A choice stored in the previous file, by what it did rather than what
    /// it was called, so nobody's transcript changes under them.
    /// </summary>
    internal static ChatDetail? Renamed(string stored) => stored.Trim().ToLowerInvariant() switch
    {
        "minimal" => ChatDetail.Compact,
        "compact" => ChatDetail.Minimal,
        "standard" => ChatDetail.Standard,
        "detailed" => ChatDetail.Detailed,
        _ => null,
    };
}
