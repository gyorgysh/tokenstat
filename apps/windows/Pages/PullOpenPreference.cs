// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
namespace Tokenstat.Pages;

internal enum PullOpenChoice { Ask, Here, Browser }

/// <summary>
/// Where opening a chat's pull request leads, on this computer. Asks until
/// somebody says to remember the answer. A plain file, because this app is
/// unpackaged and ApplicationData.Current throws there.
/// </summary>
internal static class PullOpenPreference
{
    private static PullOpenChoice? _choice;

    internal static string FilePath { get; set; } = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "tokenstat", "pulls-open-in.txt");

    public static PullOpenChoice Choice
    {
        get => _choice ??= Load();
        set
        {
            _choice = value;
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
                File.WriteAllText(FilePath, Key(value));
            }
            catch
            {
            }
        }
    }

    public static string Key(PullOpenChoice choice) => choice switch
    {
        PullOpenChoice.Here => "here",
        PullOpenChoice.Browser => "browser",
        _ => "ask",
    };

    public static PullOpenChoice Parse(string? stored) => stored?.Trim() switch
    {
        "here" => PullOpenChoice.Here,
        "browser" => PullOpenChoice.Browser,
        _ => PullOpenChoice.Ask,
    };

    internal static void Forget() => _choice = null;

    private static PullOpenChoice Load()
    {
        try { return File.Exists(FilePath) ? Parse(File.ReadAllText(FilePath)) : PullOpenChoice.Ask; }
        catch { return PullOpenChoice.Ask; }
    }
}
