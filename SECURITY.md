# Security

Ajar changes who can become root on your machine. This page says plainly what it protects
and what it does not, so you can decide whether it fits how you work.

## Reporting a vulnerability

Please use GitHub's private reporting:
**Security → Report a vulnerability** on <https://github.com/techbysakh963/ajar>.
Do not open a public issue for security problems. You will get a reply within 7 days.

## What Ajar is

Passwordless sudo, made switchable. When it is **on**, the file
`/etc/sudoers.d/90-ajar-<you>` contains one line, `<you> ALL=(ALL) NOPASSWD: ALL`, and sudo
stops asking for your password. When it is **off**, that file does not exist and sudo
behaves exactly as your system's own sudoers configuration says.

## The one sentence to remember

> **While Ajar is on, any program running as you can become root without asking.**

That is not a bug or a side effect. It is what passwordless sudo means. A browser exploit, a
malicious package in a `npm install`, a script you pasted, or an AI coding agent that does
something you did not expect: all of them get root, silently, for as long as it is on.
Ajar's job is to make that state **deliberate, visible and easy to end**, not to make it safe.

## What Ajar protects

| Promise | How |
|---|---|
| Turning on always needs an administrator's password | polkit action `io.github.techbysakh963.ajar.enable` is `auth_admin` for every kind of session (active, inactive, remote). Not `auth_admin_keep`: it asks every time. |
| A program running as you cannot turn it on by itself | The only root code is `/usr/libexec/ajar/enable`, reachable through `pkexec`, which asks polkit, which asks *you* in a system dialog the program cannot fill in. |
| Turning off is instant, but only from your own seat | `…ajar.disable` is `yes` (no password) only for the **active local session**. SSH and inactive sessions must authenticate. |
| Ajar never gives sudo to someone who lacks it | The enable helper refuses any user who is not already allowed to run everything as root with a password (an admin group, or a sudoers rule). Ajar only removes the prompt. An administrator typing their password into a standard user's dialog does not make that user root. |
| Nothing in your environment chooses what runs as root | The CLI pins `PATH`, hard-codes the helper paths, and runs as `bash -p` (ignores `BASH_ENV` and exported functions). The front ends call `ajar` by absolute path, never through `PATH`. |
| One user cannot change another user's state | The helpers act only on the user pkexec reports in `PKEXEC_UID`, which the caller cannot forge. Each user has their own file. |
| The state you see is the real state | Every front end asks `sudo -n -l` (what sudo itself will do), never a saved flag. If another sudoers rule gives you passwordless sudo, Ajar says **"open by another rule"**, not "off". |
| "Can't tell" is never shown as "off" | If Ajar's rule exists but sudo refuses to list rules without a password (`Defaults listpw=always`), the state is **unknown** and shown as open, with Turn off available. |
| A broken rule never reaches sudo | The rule is written to a dotted temp file (sudo ignores names with a dot), checked with `visudo -cf`, then renamed into place atomically. |
| You can see what happened | Every on, off and reminder is logged: `journalctl -t ajar`. |
| Uninstalling closes the door | The `.deb`'s `prerm` and `ajar uninstall` both remove every `90-ajar-*` rule first. |

## What Ajar does not protect

- **Anything that happens while it is on.** See above. Root is root.
- **It does not turn itself off.** This is a deliberate choice. The optional reminder
  (`ajar on --remind 30m`) *asks* you, with a **Turn off** button; it never removes access by
  itself. Long-running jobs (package upgrades, builds, AI agents mid-task) that lose sudo
  halfway can leave a system half-configured, and we judged that worse than a reminder you can
  dismiss. The trade-off is that a forgotten "on" stays on. The amber door in the panel and the
  reminders are the defences against forgetting; there is no hard expiry.
- **Your admin password.** If someone has it, they can turn Ajar on, but they could also just
  use sudo. Ajar adds no new way in.
- **Rules it did not write.** If your sudoers already grants passwordless sudo (a cloud image's
  `90-cloud-init-users`, Kali's `kali-trusted` group, a line you added years ago), Ajar shows
  it and `ajar doctor` points at it, but turning Ajar off does not remove it.
  `install.sh --lockdown` can remove exact per-user `NOPASSWD: ALL` lines and take you out of
  `kali-trusted`, but only if you would still have sudo afterwards (admin group and a usable
  password); otherwise it reports and changes nothing. Each edit is made on a copy, checked
  with `visudo`, and moved into place, with a backup. Group rules and anything unusual are
  reported, never edited.
- **Narrow passwordless rules.** The state shown is about running *everything* as root without
  a password. A rule like `you ALL=(root) NOPASSWD: /bin/bash` (or an editor, `env`, `find`…)
  is root too. Ajar counts such rules and mentions them in `ajar status` and `ajar doctor`,
  but does not light the amber door for them.
- **polkit rules that override the policy.** A rules file in `/etc/polkit-1/rules.d` or
  `/usr/share/polkit-1/rules.d` can allow any action without a password. For example, systemd's
  `empower.rules` allows every action for members of the `empower` group (`run0 --empower`).
  `ajar doctor` asks polkit for its real verdict (`pkcheck`) and warns if turning on would
  not ask for a password.
- **Sessions you leave unlocked.** Turning off needs no password from the active session, by
  design. Someone at your unlocked desk can turn it off (harmless) and, if it is already on,
  use root (not harmless). Lock your screen.

## Who should not use Ajar

- Shared or multi-user machines where you are not the only administrator.
- Servers, or any machine reachable by people you do not trust.
- Anyone who would leave it on all the time. Then you do not want Ajar; you want to decide,
  consciously, to configure `NOPASSWD` permanently.

## Installing safely

- Prefer the `.deb` from the release page, or download `install.sh`, read it, then run it.
- `curl -fsSL …/install.sh | bash` is supported. The script is wrapped in one function called
  on its last line, so a truncated download runs nothing. It prints every change and asks
  before making any (`--dry-run` shows the plan and stops). A release copy of `install.sh`
  embeds the SHA-256 of that release's tarball and refuses anything else.
- Release assets are pinned to a version tag. `SHA256SUMS` is published alongside them.

## Review history

Before 1.0.0, every privileged script was reviewed independently (the reviewer saw the code,
not our reasoning). No critical issues. Fixed as a result, each with a regression test:
removing the `.deb` from Synaptic or `pkexec apt` left passwordless sudo on (reproduced, then
fixed); enable could grant sudo to a user without it; `BASH_ENV`/`PATH` could steer which
program asked for the password (reproduced); lockdown could remove a password-less user's
only route to root; the uninstall manifest allowlist was too broad; and smaller correctness
issues. The list is in the git history (`git log --grep=review`).

## How it is tested

What CI checks on every push: shellcheck on every shell script; no shell function defined twice
(a later one silently replaces the first, and that happened once during development); the
`sudo -l` parser against real output recorded on Debian 12/13, Kali, Ubuntu 24.04 and Ubuntu
26.04 (sudo-rs); unit tests of the GNOME toggle's logic.

What runs in throwaway containers on all five distributions: the installer (including
lockdown), the root helpers, the state machine against that distribution's real sudo, the
`.deb` install/remove/purge, and the `curl | bash` path with a truncated script and a tampered
tarball.

**What is not automated, on purpose:** turning Ajar on through the real password dialog. An
automated test that can succeed at that would be a test that grants root without a human. The
gating is checked with `pkcheck` (which returns polkit's verdict and never shows a dialog), and
the dialog itself is checked by hand before each release:

1. `ajar status` says OFF.
2. Run `ajar on`. A password dialog appears. Cancel it. `ajar status` still says OFF.
3. Run `ajar on` again and authenticate. `ajar status` says ON; the panel shows the amber door.
4. Run `ajar off`. No dialog. `ajar status` says OFF.
