// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
namespace Tokenstat.Pages;

/// <summary>Native browsers are bounded per reply and per eager transcript.</summary>
internal sealed class ChartRenderBudget(int limit = ChartRenderBudget.PerMessage, ChartRenderBudget? shared = null)
{
    internal const int PerMessage = 4;
    internal const int PerTranscript = 8;
    private int _remaining = Math.Max(0, limit);

    internal bool TryTake()
    {
        if (_remaining == 0 || shared is not null && !shared.TryTake()) return false;
        _remaining--;
        return true;
    }
}
