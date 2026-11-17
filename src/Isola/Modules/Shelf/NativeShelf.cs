using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace Isola.Modules.Shelf;

/// <summary>Shell icons for the Shelf module (SHGetFileInfo), cached by extension.</summary>
internal static class NativeShelf
{
    private const uint SHGFI_ICON = 0x100;
    private const uint SHGFI_LARGEICON = 0x0;
    private const uint SHGFI_USEFILEATTRIBUTES = 0x10;
    private const uint FILE_ATTRIBUTE_NORMAL = 0x80;
    private const uint FILE_ATTRIBUTE_DIRECTORY = 0x10;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct SHFILEINFO
    {
        public IntPtr hIcon;
        public int iIcon;
        public uint dwAttributes;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string szDisplayName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 80)] public string szTypeName;
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr SHGetFileInfo(string path, uint attributes, ref SHFILEINFO info, uint size, uint flags);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DestroyIcon(IntPtr hIcon);

    private static readonly Dictionary<string, ImageSource?> Cache = new(StringComparer.OrdinalIgnoreCase);

    /// <summary>Extensions whose icon depends on the file itself (not cached by extension).</summary>
    private static readonly HashSet<string> PerFile = new(StringComparer.OrdinalIgnoreCase) { ".exe", ".lnk", ".ico", ".url", ".appref-ms", ".msc", ".cpl" };

    /// <summary>The 32x32 shell icon. Call on the UI thread.</summary>
    public static ImageSource? Icon(string path, bool isDirectory, bool exists)
    {
        string ext = isDirectory ? "<dir>" : Path.GetExtension(path);
        bool perFile = exists && !isDirectory && PerFile.Contains(ext);
        string key = perFile ? path : ext;
        if (Cache.TryGetValue(key, out var cached)) return cached;

        var info = new SHFILEINFO();
        uint flags = SHGFI_ICON | SHGFI_LARGEICON;
        uint attrs = 0;
        string query = path;
        if (!perFile)
        {
            // By type only: fast, no disk access, works for missing files too.
            flags |= SHGFI_USEFILEATTRIBUTES;
            attrs = isDirectory ? FILE_ATTRIBUTE_DIRECTORY : FILE_ATTRIBUTE_NORMAL;
            query = isDirectory ? "cartella" : "file" + ext;
        }
        ImageSource? img = null;
        try
        {
            if (SHGetFileInfo(query, attrs, ref info, (uint)Marshal.SizeOf<SHFILEINFO>(), flags) != IntPtr.Zero && info.hIcon != IntPtr.Zero)
            {
                try
                {
                    var src = Imaging.CreateBitmapSourceFromHIcon(info.hIcon, Int32Rect.Empty, BitmapSizeOptions.FromEmptyOptions());
                    src.Freeze();
                    img = src;
                }
                finally { DestroyIcon(info.hIcon); }
            }
        }
        catch { img = null; }
        if (Cache.Count > 512) Cache.Clear();
        Cache[key] = img;
        return img;
    }
}
