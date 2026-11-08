// Talks to the `ajar` CLI. Plain GLib/Gio, no Shell imports, so tests can load it with `gjs -m`.
// The extension never decides the state itself: it asks `ajar status --json` after every action.
import GLib from 'gi://GLib';
import Gio from 'gi://Gio';

export const STATES = ['on', 'off', 'external', 'stale', 'unavailable'];

export function ajarPath() {
    return GLib.find_program_in_path('ajar') ?? '/usr/bin/ajar';
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
        open: s.state === 'on' || s.state === 'external',   // is sudo passwordless right now?
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
    default:         return 'Not installed';
    }
}

/** Icon name for a state (files ship in the extension's icons/ folder). */
export function iconFor(st) {
    if (st.state === 'external')
        return 'ajar-external-symbolic';
    return st.open ? 'ajar-open-symbolic' : 'ajar-closed-symbolic';
}

export function run(argv) {
    return new Promise(resolve => {
        let proc;
        try {
            proc = Gio.Subprocess.new(argv,
                Gio.SubprocessFlags.STDOUT_PIPE | Gio.SubprocessFlags.STDERR_PIPE);
        } catch (e) {
            resolve({ok: false, status: -1, stdout: '', stderr: String(e)});
            return;
        }
        proc.communicate_utf8_async(null, null, (p, res) => {
            try {
                const [, stdout, stderr] = p.communicate_utf8_finish(res);
                resolve({ok: p.get_successful(), status: p.get_exit_status(), stdout, stderr});
            } catch (e) {
                resolve({ok: false, status: -1, stdout: '', stderr: String(e)});
            }
        });
    });
}

export async function status() {
    const r = await run([ajarPath(), 'status', '--json']);
    return parseStatus(r.ok ? r.stdout : '');
}

/** Turn on (shows the polkit password dialog). remind: '15m' | '1h' | null */
export async function turnOn(remind = null) {
    const argv = [ajarPath(), 'on'];
    if (remind)
        argv.push('--remind', remind);
    const r = await run(argv);
    // 126 = dialog dismissed; 127 = not authorized / no agent (see `ajar on`)
    return {ok: r.ok, cancelled: r.status === 126, error: r.ok ? null : r.stderr.trim()};
}

export async function turnOff() {
    const r = await run([ajarPath(), 'off']);
    return {ok: r.ok, external: r.status === 5, error: r.ok ? null : (r.stdout + r.stderr).trim()};
}

export async function remind(arg) {
    const r = await run([ajarPath(), 'remind', arg]);
    return {ok: r.ok, error: r.ok ? null : r.stderr.trim()};
}
