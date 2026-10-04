// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE.

namespace Tokenstat.Pages;

/// <summary>
/// The chosen transcript detail level, one for every chat on this computer,
/// like the Mac's <c>chat.detail</c> default. Compact until somebody picks.
///
/// A plain file, not LocalSettings: this app is unpackaged, and
/// ApplicationData.Current throws there.
/// </summary>
internal static class ChatDetailPreference
{
    private static ChatDetail? _level;

    private static string FilePath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "tokenstat",
        "chat-detail.txt");

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
        }
        catch
        {
            // A damaged file only costs the remembered level.
        }
        return ChatDetail.Compact;
    }
}
