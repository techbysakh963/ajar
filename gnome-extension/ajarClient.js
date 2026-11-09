// Talks to the `ajar` CLI. Plain GLib/Gio, no Shell imports, so tests can load it with `gjs -m`.
// The extension never decides the state itself: it asks `ajar status --json` after every action.
import GLib from 'gi://GLib';
import Gio from 'gi://Gio';

export const STATES = ['on', 'off', 'external', 'stale', 'unknown', 'unavailable'];

// Absolute paths only: a PATH lookup would let anything that can write ~/.local/bin decide
// which program the toggle runs (and so which program asks for your password).
export const AJAR_PATHS = ['/usr/bin/ajar', '/usr/local/bin/ajar'];

export function ajarPath() {
    return AJAR_PATHS.find(p => GLib.file_test(p, GLib.FileTest.IS_EXECUTABLE)) ?? AJAR_PATHS[0];
}

/** Normalize `ajar status --json` output. Anything unexpected becomes {state: 'unavailable'}. */
export function parseStatus(text) {
    let s;
    try {
        s = JSON.parse(text ?? '');
    } catch {
        return {state: 'unavailable', open: false, remindAt: null};
    }
    if (!s || !STATES.includes(s.state))
        return {state: 'unavailable', open: false, remindAt: null};
    const remindAt = typeof s.remind_at === 'string' ? new Date(s.remind_at) : null;
    return {
        state: s.state,
        // is sudo (or may it be) passwordless right now? "unknown" counts as open, never as off
        open: s.state === 'on' || s.state === 'external' || s.state === 'unknown',
        ours: s.ours === true,
        external: s.external === true,
        remindAt: remindAt && !isNaN(remindAt) ? remindAt : null,
    };
}

function hhmm(date) {
    return `${String(date.getHours()).padStart(2, '0')}:${String(date.getMinutes()).padStart(2, '0')}`;
}

/** Short subtitle for the Quick Settings toggle. */
export function describe(st) {
    switch (st.state) {
    case 'on':       return st.remindAt ? `No password · reminder ${hhmm(st.remindAt)}` : 'No password';
    case 'off':      return 'Asks for password';
    case 'external': return 'Open by another rule';
    case 'stale':    return 'Rule overridden';
    case 'unknown':  return 'Probably on · cannot verify';
    default:         return 'Not installed';
    }
}

/** Icon name for a state (files ship in the extension's icons/ folder). */
export function iconFor(st) {
    if (st.state === 'external' || st.state === 'unknown')
        return 'ajar-external-symbolic';
    return st.open ? 'ajar-open-symbolic' : 'ajar-closed-symbolic';
}

/** Run argv; resolves with its result. Cancelling `cancellable` stops the process. */
export function run(argv, cancellable = null) {
    return new Promise(resolve => {
        let proc;
        try {
            proc = Gio.Subprocess.new(argv,
                Gio.SubprocessFlags.STDOUT_PIPE | Gio.SubprocessFlags.STDERR_PIPE);
        } catch (e) {
            resolve({ok: false, status: -1, stdout: '', stderr: String(e)});
            return;
        }
        cancellable?.connect(() => proc.force_exit());
        proc.communicate_utf8_async(null, cancellable, (p, res) => {
            try {
                const [, stdout, stderr] = p.communicate_utf8_finish(res);
                resolve({ok: p.get_successful(), status: p.get_exit_status(), stdout, stderr});
            } catch (e) {
                resolve({ok: false, status: -1, stdout: '', stderr: String(e)});
            }
        });
    });
}

export async function status(cancellable = null) {
    const r = await run([ajarPath(), 'status', '--json'], cancellable);
    return parseStatus(r.ok ? r.stdout : '');
}

/** Turn on (shows the polkit password dialog). remind: '15m' | '1h' | null */
export async function turnOn(remind = null, cancellable = null) {
    const argv = [ajarPath(), 'on'];
    if (remind)
        argv.push('--remind', remind);
    const r = await run(argv, cancellable);
    // 126 = dialog dismissed; 127 = not authorized / no agent (see `ajar on`)
    return {ok: r.ok, cancelled: r.status === 126, error: r.ok ? null : r.stderr.trim()};
}

export async function turnOff(cancellable = null) {
    const r = await run([ajarPath(), 'off'], cancellable);
    return {ok: r.ok, external: r.status === 5, error: r.ok ? null : (r.stdout + r.stderr).trim()};
}

export async function remind(arg, cancellable = null) {
    const r = await run([ajarPath(), 'remind', arg], cancellable);
    return {ok: r.ok, error: r.ok ? null : r.stderr.trim()};
}
