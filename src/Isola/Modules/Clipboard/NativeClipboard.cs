using System.Runtime.InteropServices;
using System.Text;

namespace Isola.Modules.Clipboard;

/// <summary>Win32 clipboard calls used only by the Clipboard module. Reading goes through Win32
/// (not the WPF Clipboard class) so a busy clipboard fails fast instead of blocking the UI thread.</summary>
internal static class NativeClipboard
{
    public const int WM_CLIPBOARDUPDATE = 0x031D;
    public const uint CF_UNICODETEXT = 13;
    public const uint CF_DIB = 8;
    public const uint CF_HDROP = 15;

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool AddClipboardFormatListener(IntPtr hwnd);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool RemoveClipboardFormatListener(IntPtr hwnd);

    [DllImport("user32.dll")]
    public static extern uint GetClipboardSequenceNumber();

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool OpenClipboard(IntPtr hwnd);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool CloseClipboard();

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool IsClipboardFormatAvailable(uint format);

    [DllImport("user32.dll")]
    public static extern IntPtr GetClipboardData(uint format);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern uint RegisterClipboardFormat(string name);

    [DllImport("kernel32.dll")]
    public static extern IntPtr GlobalLock(IntPtr hMem);

    [DllImport("kernel32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool GlobalUnlock(IntPtr hMem);

    [DllImport("kernel32.dll")]
    public static extern UIntPtr GlobalSize(IntPtr hMem);

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    public static extern uint DragQueryFile(IntPtr hDrop, uint iFile, StringBuilder? file, uint cch);

    /// <summary>Copies the bytes of an HGLOBAL clipboard handle (null if empty or too big).</summary>
    public static byte[]? ReadGlobal(IntPtr h, long maxBytes)
    {
        if (h == IntPtr.Zero) return null;
        long size = (long)GlobalSize(h).ToUInt64();
        if (size <= 0 || size > maxBytes) return null;
        var p = GlobalLock(h);
        if (p == IntPtr.Zero) return null;
        try
        {
            var bytes = new byte[size];
            Marshal.Copy(p, bytes, 0, (int)size);
            return bytes;
        }
        finally { GlobalUnlock(h); }
    }

    public static string? ReadUnicodeText(IntPtr h, int maxChars)
    {
        if (h == IntPtr.Zero) return null;
        var p = GlobalLock(h);
        if (p == IntPtr.Zero) return null;
        try
        {
            long bytes = (long)GlobalSize(h).ToUInt64();
            int chars = (int)Math.Min(bytes / 2, maxChars);
            var s = Marshal.PtrToStringUni(p, chars);
            int nul = s.IndexOf('\0');
            return nul >= 0 ? s[..nul] : s;
        }
        finally { GlobalUnlock(h); }
    }

    public static List<string> ReadFileDrop(IntPtr h)
    {
        var list = new List<string>();
        if (h == IntPtr.Zero) return list;
        uint count = DragQueryFile(h, 0xFFFFFFFF, null, 0);
        for (uint i = 0; i < count && i < 500; i++)
        {
            uint len = DragQueryFile(h, i, null, 0);
            var sb = new StringBuilder((int)len + 1);
            if (DragQueryFile(h, i, sb, len + 1) > 0) list.Add(sb.ToString());
        }
        return list;
    }
}
