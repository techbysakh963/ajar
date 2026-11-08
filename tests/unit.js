// gjs -m tests/unit.js   (no root, no Shell; tests the logic the GNOME toggle uses)
import GLib from 'gi://GLib';
import {parseStatus, describe, iconFor, run} from '../gnome-extension/ajarClient.js';

let bad = 0, n = 0;
const eq = (name, got, want) => {
    n++;
    if (JSON.stringify(got) !== JSON.stringify(want)) {
        bad++;
        print(`FAIL ${name}: got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`);
    }
};
const js = o => JSON.stringify({ours: false, external: false, user: 'u', sudo: 's', remind_at: null, version: '1', ...o});

// parseStatus: every state, and garbage
eq('on is open',            parseStatus(js({state: 'on', ours: true})).open, true);
eq('external is open',      parseStatus(js({state: 'external', external: true})).open, true);
eq('off is closed',         parseStatus(js({state: 'off'})).open, false);
eq('stale is closed',       parseStatus(js({state: 'stale', ours: true})).open, false);
eq('garbage -> unavailable', parseStatus('not json').state, 'unavailable');
eq('empty -> unavailable',  parseStatus('').state, 'unavailable');
eq('null -> unavailable',   parseStatus(null).state, 'unavailable');
eq('unknown state rejected', parseStatus(js({state: 'maybe'})).state, 'unavailable');
eq('bad date -> null',      parseStatus(js({state: 'on', remind_at: 'nope'})).remindAt, null);
const withRemind = parseStatus(js({state: 'on', remind_at: '2026-11-08T23:16:52+03:00'}));
eq('remind date parsed',    withRemind.remindAt instanceof Date, true);

// describe / iconFor
eq('describe off',          describe(parseStatus(js({state: 'off'}))), 'Asks for password');
eq('describe on',           describe(parseStatus(js({state: 'on'}))), 'No password');
eq('describe on+reminder',  /^No password · reminder \d\d:\d\d$/.test(describe(withRemind)), true);
eq('describe external',     describe(parseStatus(js({state: 'external'}))), 'Open by another rule');
eq('describe unavailable',  describe(parseStatus('')), 'Not installed');
eq('icon off',              iconFor(parseStatus(js({state: 'off'}))), 'ajar-closed-symbolic');
eq('icon on',               iconFor(parseStatus(js({state: 'on'}))), 'ajar-open-symbolic');
eq('icon external',         iconFor(parseStatus(js({state: 'external'}))), 'ajar-external-symbolic');
eq('icon stale',            iconFor(parseStatus(js({state: 'stale'}))), 'ajar-closed-symbolic');
eq('unknown is open',       parseStatus(js({state: 'unknown', ours: true})).open, true);
eq('icon unknown',          iconFor(parseStatus(js({state: 'unknown'}))), 'ajar-external-symbolic');
eq('describe unknown',      describe(parseStatus(js({state: 'unknown'}))), 'Probably on · cannot verify');

// round trip with the real CLI from this checkout (read-only: `status --json`)
const cli = GLib.build_filenamev([GLib.path_get_dirname(GLib.path_get_dirname(
    GLib.filename_from_uri(import.meta.url)[0])), 'bin', 'ajar']);
const loop = new GLib.MainLoop(null, false);
run([cli, 'status', '--json']).then(r => {
    const st = parseStatus(r.stdout);
    eq('real CLI status parses', r.ok && st.state !== 'unavailable', true);
    loop.quit();
});
loop.run();

print(bad ? `unit: ${bad}/${n} failed` : `unit: ${n}/${n} ok`);
imports.system.exit(bad ? 1 : 0);
