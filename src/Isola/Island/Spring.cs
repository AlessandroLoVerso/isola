using System.Windows.Media;

namespace Isola.Island;

/// <summary>A damped spring (mass 1). Response = period in seconds, Damping = damping ratio.</summary>
internal sealed class Spring
{
    public double Value;
    public double Velocity;
    public double Target;
    public double Response = 0.45;
    public double Damping = 0.8;

    public Spring(double value)
    {
        Value = value;
        Target = value;
    }

    public void Step(double dt)
    {
        double omega = 2 * Math.PI / Response;
        double k = omega * omega;
        double c = 2 * Damping * omega;
        double a = -k * (Value - Target) - c * Velocity;
        Velocity += a * dt;           // semi-implicit Euler: stable at small dt
        Value += Velocity * dt;
    }

    public bool IsSettled => Math.Abs(Value - Target) < 0.02 && Math.Abs(Velocity) < 0.6;

    public void Snap()
    {
        Value = Target;
        Velocity = 0;
    }
}

/// <summary>Drives a set of springs from CompositionTarget.Rendering and detaches itself when
/// every spring has settled, so there is no per-frame work at rest.</summary>
internal sealed class SpringAnimator
{
    private const double SubStep = 1.0 / 240;
    private readonly Spring[] _springs;
    private bool _attached;
    private TimeSpan _last;

    public SpringAnimator(params Spring[] springs) => _springs = springs;

    /// <summary>Raised after each integration step (and once more when settled).</summary>
    public event Action? Frame;

    public bool IsRunning => _attached;

    public void Kick()
    {
        if (_attached) return;
        _attached = true;
        _last = TimeSpan.Zero;
        CompositionTarget.Rendering += OnRendering;
    }

    public void SnapAll()
    {
        foreach (var s in _springs) s.Snap();
        Frame?.Invoke();
    }

    private void OnRendering(object? sender, EventArgs e)
    {
        try { Step(e); }
        catch (Exception ex)
        {
            // Never keep throwing once per frame: snap to the targets and detach.
            CompositionTarget.Rendering -= OnRendering;
            _attached = false;
            Isola.Core.Log.Error("Errore nell'animazione dell'isola", ex);
            try { SnapAll(); } catch { /* logged above */ }
        }
    }

    private void Step(EventArgs e)
    {
        var now = e is RenderingEventArgs re ? re.RenderingTime : TimeSpan.FromTicks(Environment.TickCount64 * 10_000);
        double dt;
        if (_last == TimeSpan.Zero) dt = 1.0 / 60;
        else if (now == _last) return; // Rendering can fire more than once per frame
        else dt = Math.Min((now - _last).TotalSeconds, 1.0 / 20);
        _last = now;

        int steps = Math.Max(1, (int)Math.Ceiling(dt / SubStep));
        double h = dt / steps;
        for (int i = 0; i < steps; i++)
            foreach (var s in _springs) s.Step(h);

        bool settled = true;
        foreach (var s in _springs)
            if (!s.IsSettled) { settled = false; break; }

        if (settled)
        {
            foreach (var s in _springs) s.Snap();
            CompositionTarget.Rendering -= OnRendering;
            _attached = false;
        }
        Frame?.Invoke();
    }
}
