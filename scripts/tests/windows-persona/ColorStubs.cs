// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Only colour storage is substituted; tests run the production simulation.
namespace Windows.UI
{
    internal readonly record struct Color(byte A, byte R, byte G, byte B)
    {
        public static Color FromArgb(byte a, byte r, byte g, byte b) => new(a, r, g, b);
    }
}
namespace Tokenstat.Design
{
    internal static class Theme
    {
        public static Windows.UI.Color Accent => new(255, 139, 92, 246);
        public static Windows.UI.Color Secondary => new(255, 232, 121, 249);
        public static Windows.UI.Color Warning => new(255, 224, 169, 59);
        public static Windows.UI.Color Danger => new(255, 214, 69, 63);
    }
}
