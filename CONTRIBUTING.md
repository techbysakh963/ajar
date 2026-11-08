# Contributing to Ajar

Thanks for helping. Ajar is small on purpose: the code that runs as root is two short shell
scripts, and every change is judged first by whether it keeps them short and obvious.

## Layout

| Path | Runs as | What it is |
|---|---|---|
| `libexec/enable`, `libexec/disable` | **root**, via pkexec | The only privileged code. Write or remove `/etc/sudoers.d/90-ajar-<user>`. |
| `polkit/*.policy` | polkit | Who may run the helpers, and whether a password is needed. |
| `bin/ajar` | you | The CLI every front end uses. Reads the real state from `sudo -n -l`. |
| `gnome-extension/` | GNOME Shell | Quick Settings toggle, GNOME 45 to 50. |
| `tray/ajar-tray` | you | Tray icon (StatusNotifierItem) for Xfce, KDE, MATE, Cinnamon, GNOME 43/44. |
| `share/ajar-ask` | you | Notification with buttons, used by the reminder. |
| `install.sh`, `tools/` | you + sudo | Installer, `.deb` and release builders. |

## Tests

```bash
tests/static.sh                 # shellcheck, duplicate functions, syntax (no root, seconds)
tests/parser.sh                 # sudo -l parser vs. real output from five distros
gjs -m tests/unit.js            # GNOME toggle logic
tests/matrix.sh [image...]      # installer + helpers + uninstall in containers (needs docker/podman)
tools/build-deb.sh && tests/deb-matrix.sh
tools/make-release.sh && tests/curl-pipe.sh
tests/e2e.sh                    # your real system; read its header first
tests/gnome-nested.sh start     # real GNOME Shell, headless, in a throwaway session
```

Recording parser fixtures for a new distribution or sudo version:
`tests/fixtures/capture-sudo-l.sh <image> <label>` (runs only inside a container).

## Rules for changes

1. **Never write a test that can turn Ajar on through polkit.** A test that can succeed at that
   is a test that grants root without a human typing a password. Use `pkcheck` without
   `--allow-user-interaction` to check gating, and call the helper with `PKEXEC_UID` only
   inside a container. See "How it is tested" in [SECURITY.md](SECURITY.md).
2. **Changes to `libexec/` or the polkit policy need a written justification** in the pull
   request, and a matching test in `tests/matrix.sh` or `tests/e2e.sh`.
3. **The displayed state must come from sudo.** Never cache or assume it.
4. **Do not silence shellcheck to make it pass.** If a warning is wrong, say why in a comment
   next to the `disable` line. (We once silenced "this function is never invoked"; it was
   true, and the reminder's Turn off button was dead until we noticed.)
5. Keep commits small, and say *why* in the message.

## Releasing

1. Bump `VERSION` in `bin/ajar` and `version-name` in `gnome-extension/metadata.json`.
2. Run every test above, plus the manual dialog check in SECURITY.md, on a real desktop.
3. `tools/make-release.sh`, then attach everything in `dist/` to a GitHub release for tag `vX.Y.Z`.
