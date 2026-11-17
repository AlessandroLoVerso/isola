using Isola.Core;
using static Isola.Native.NativeMethods;

namespace Isola.Island;

/// <summary>Watches the foreground window with WinEvent hooks (out of context, event driven:
/// no polling). Also watches the foreground window's own moves/resizes, so a browser video that
/// goes fullscreen without changing the foreground window is noticed too.</summary>
internal sealed class ForegroundWatcher : IDisposable
{
    private readonly WinEventDelegate _proc; // kept alive: native code holds a pointer to it
    private IntPtr _foregroundHook;
    private IntPtr _locationHook;
    private IntPtr _watched;

    public ForegroundWatcher()
    {
        _proc = OnWinEvent;
    }

    /// <summary>New foreground window (another process).</summary>
    public event Action<IntPtr>? ForegroundChanged;

    /// <summary>The current foreground window moved or was resized.</summary>
    public event Action<IntPtr>? ForegroundMoved;

    public IntPtr Current => _watched;

    public void Start()
    {
        _foregroundHook = SetWinEventHook(EVENT_SYSTEM_FOREGROUND, EVENT_SYSTEM_FOREGROUND, IntPtr.Zero, _proc,
            0, 0, WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS);
        if (_foregroundHook == IntPtr.Zero) Log.Warn("SetWinEventHook(EVENT_SYSTEM_FOREGROUND) non riuscito");
        Watch(GetForegroundWindow());
    }

    private void Watch(IntPtr hwnd)
    {
        if (_locationHook != IntPtr.Zero)
        {
            UnhookWinEvent(_locationHook);
            _locationHook = IntPtr.Zero;
        }
        _watched = hwnd;
        if (hwnd == IntPtr.Zero) return;

        uint tid = GetWindowThreadProcessId(hwnd, out uint pid);
        if (tid == 0 || pid == (uint)Environment.ProcessId) return;
        // Scoped to the foreground window's thread: only its own location events reach us.
        _locationHook = SetWinEventHook(EVENT_OBJECT_LOCATIONCHANGE, EVENT_OBJECT_LOCATIONCHANGE, IntPtr.Zero, _proc,
            pid, tid, WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS);
    }

    private void OnWinEvent(IntPtr hook, uint eventType, IntPtr hwnd, int idObject, int idChild, uint thread, uint time)
    {
        // Runs on the UI thread (out-of-context hooks are delivered through its message loop).
        // Never let an exception cross back into native code.
        try
        {
            if (eventType == EVENT_SYSTEM_FOREGROUND)
            {
                Watch(hwnd);
                ForegroundChanged?.Invoke(hwnd);
            }
            else if (eventType == EVENT_OBJECT_LOCATIONCHANGE)
            {
                if (hwnd == _watched && idObject == OBJID_WINDOW && idChild == CHILDID_SELF)
                    ForegroundMoved?.Invoke(hwnd);
            }
        }
        catch (Exception ex)
        {
            Log.Error("Errore nel gestore del primo piano", ex);
        }
    }

    public void Dispose()
    {
        if (_foregroundHook != IntPtr.Zero) UnhookWinEvent(_foregroundHook);
        if (_locationHook != IntPtr.Zero) UnhookWinEvent(_locationHook);
        _foregroundHook = _locationHook = IntPtr.Zero;
    }
}
