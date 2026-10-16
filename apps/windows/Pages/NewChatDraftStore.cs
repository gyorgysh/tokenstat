// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
namespace Tokenstat.Pages;

internal sealed record NewChatDraft(string Text, NewChatFile[] Files, NewChatSetup? Setup)
{
    internal static NewChatDraft Empty => new("", [], null);
}

/// A page owns one account generation; repository IDs include the remote host.
/// Unbound writing follows the first explicit repository selection once only.
internal sealed class NewChatDraftStore
{
    private readonly Dictionary<string, NewChatDraft> _drafts = new();
    private bool _hasSelectedRepository;
    internal string? Repository { get; private set; }
    internal long Revision { get; private set; }

    internal void Remember(NewChatDraft draft) => _drafts[Repository ?? ""] = draft;

    internal bool AcceptsFiles(string? repository, long revision) =>
        Repository == repository && Revision == revision
        || repository is null && revision == 0 && Repository is not null && Revision == 1;

    internal void DiscardFiles()
    {
        foreach (var file in _drafts.Values.SelectMany(draft => draft.Files).DistinctBy(file => file.Path)) file.Discard();
        _drafts.Clear();
    }

    internal NewChatDraft Select(string? repository, NewChatDraft current, bool adoptUnbound = true)
    {
        Remember(current);
        if (Repository == repository) return current;
        // A folder shown before anyone chooses one is not a selection. The
        // unbound draft stays unbound, and the first explicit choice adopts it.
        if (!adoptUnbound) return current;
        if (repository is not null && !_hasSelectedRepository && Repository is null && !_drafts.ContainsKey(repository))
        {
            _drafts[repository] = current;
            _drafts.Remove("");
        }
        Repository = repository;
        _hasSelectedRepository |= repository is not null;
        Revision++;
        return _drafts.GetValueOrDefault(repository ?? "") ?? NewChatDraft.Empty;
    }
}
