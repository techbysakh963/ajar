// Ajar: Quick Settings toggle for passwordless sudo (GNOME Shell 45-50).
import GObject from 'gi://GObject';
import GLib from 'gi://GLib';
import Gio from 'gi://Gio';

import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';
import {QuickMenuToggle, SystemIndicator} from 'resource:///org/gnome/shell/ui/quickSettings.js';

import * as Ajar from './ajarClient.js';

const POLL_SECONDS = 60;
const SUDOERS_D = '/etc/sudoers.d';

const AjarToggle = GObject.registerClass(
class AjarToggle extends QuickMenuToggle {
    _init(ext) {
        super._init({title: 'Passwordless Sudo', toggleMode: false});
        this._ext = ext;
        this._busy = false;
        this.connect('clicked', () => this._onClicked());

        this._onItems = new PopupMenu.PopupMenuSection();
        this._onItems.addAction('Turn on, remind me in 15 minutes', () => this._on('15m'));
        this._onItems.addAction('Turn on, remind me in 1 hour', () => this._on('1h'));
        this.menu.addMenuItem(this._onItems);

        this._openItems = new PopupMenu.PopupMenuSection();
        this._openItems.addAction('Remind me in 15 minutes', () => this._remind('15m'));
        this._openItems.addAction('Remind me in 1 hour', () => this._remind('1h'));
        this._cancelItem = this._openItems.addAction('No reminder', () => this._remind('cancel'));
        this.menu.addMenuItem(this._openItems);

        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());
        this._hint = new PopupMenu.PopupMenuItem('', {reactive: false, can_focus: false});
        this._hint.label.add_style_class_name('ajar-hint');
        this._hint.label.clutter_text.line_wrap = true;
        this.menu.addMenuItem(this._hint);
    }

    show(st) {
        this._st = st;
        const icon = this._ext.icon(Ajar.iconFor(st));
        this.set({checked: st.open, gicon: icon, subtitle: Ajar.describe(st)});
        this.reactive = st.state !== 'unavailable';
        this.menu.setHeader(icon, 'Passwordless Sudo', Ajar.describe(st));
        this._onItems.actor.visible = !st.open;
        this._openItems.actor.visible = st.state === 'on';
        this._cancelItem.visible = st.remindAt !== null;
        this._hint.label.text = {
            on: 'Any program running as you can become root without asking.',
            off: 'Turning on asks for your password. Turning off never does.',
            external: 'A sudoers rule outside Ajar gives you passwordless sudo, so Ajar cannot close it. Run "ajar doctor" in a terminal.',
            stale: 'Ajar\'s rule is overridden by a later sudoers rule. Run "ajar doctor" in a terminal.',
            unavailable: 'The ajar command was not found. Reinstall Ajar.',
        }[st.state];
    }

    _onClicked() {
        if (!this._st)
            return;
        if (this._st.state === 'external') {
            Main.notify('Ajar', 'Passwordless sudo comes from a rule Ajar does not manage. Run "ajar doctor" to find it.');
            this.show(this._st);   // keep the real state, the click changed nothing
            return;
        }
        if (this._st.open)
            this._off();
        else
            this._on(null);
    }

    async _act(fn) {
        if (this._busy)
            return;
        this._busy = true;
        this.reactive = false;
        try {
            await fn();
        } finally {
            this._busy = false;
            await this._ext.refresh();   // never trust the click: re-read the real state
        }
    }

    _on(remind) {
        this.menu.close();
        return this._act(async () => {
            const r = await Ajar.turnOn(remind);
            if (!r.ok && !r.cancelled)
                Main.notifyError('Ajar', r.error || 'Could not turn on passwordless sudo.');
        });
    }

    _off() {
        return this._act(async () => {
            const r = await Ajar.turnOff();
            if (!r.ok)
                Main.notifyError('Ajar', r.error || 'Could not turn off passwordless sudo.');
        });
    }

    _remind(arg) {
        this.menu.close();
        return this._act(() => Ajar.remind(arg));
    }
});

const AjarIndicator = GObject.registerClass(
class AjarIndicator extends SystemIndicator {
    _init(ext) {
        super._init();
        this._icon = this._addIndicator();
        this._icon.add_style_class_name('ajar-warning');   // amber in the top bar
        this._icon.visible = false;                          // shown only while sudo is open
        this.toggle = new AjarToggle(ext);
        this.quickSettingsItems.push(this.toggle);
        this._ext = ext;
    }

    update(st) {
        this.toggle.show(st);
        this._icon.gicon = this._ext.icon(Ajar.iconFor(st));
        this._icon.visible = st.open;
    }
});

export default class AjarExtension extends Extension {
    enable() {
        this._icons = new Map();
        this._indicator = new AjarIndicator(this);
        Main.panel.statusArea.quickSettings.addExternalIndicator(this._indicator);

        // Refresh at once when any sudoers drop-in changes (the CLI, the tray, or a terminal),
        // and every minute for changes elsewhere (/etc/sudoers, group membership, reminders).
        this._monitor = Gio.File.new_for_path(SUDOERS_D).monitor_directory(Gio.FileMonitorFlags.NONE, null);
        this._monitorId = this._monitor.connect('changed', () => this._refreshSoon());
        this._poll = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, POLL_SECONDS, () => {
            this.refresh();
            return GLib.SOURCE_CONTINUE;
        });
        this.refresh();
    }

    icon(name) {
        if (!this._icons.has(name))
            this._icons.set(name, Gio.icon_new_for_string(`${this.path}/icons/${name}.svg`));
        return this._icons.get(name);
    }

    _refreshSoon() {
        if (this._debounce)
            return;
        this._debounce = GLib.timeout_add(GLib.PRIORITY_DEFAULT, 300, () => {
            this._debounce = 0;
            this.refresh();
            return GLib.SOURCE_REMOVE;
        });
    }

    async refresh() {
        const st = await Ajar.status();
        this._indicator?.update(st);
    }

    disable() {
        for (const id of [this._poll, this._debounce])
            if (id)
                GLib.source_remove(id);
        this._poll = this._debounce = 0;
        this._monitor?.disconnect(this._monitorId);
        this._monitor?.cancel();
        this._monitor = null;
        this._indicator?.quickSettingsItems.forEach(i => i.destroy());
        this._indicator?.destroy();
        this._indicator = null;
        this._icons = null;
    }
}
