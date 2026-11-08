# How these images were made

Every screenshot here is a real capture of a real desktop running a real Ajar install. None
are mock-ups or redrawn. This page says exactly what was done to them, so you can judge.

| Image | Desktop | Captured with |
|---|---|---|
| `hero.jpg`, `gnome-*.png`, `reminder.png`, `demo.gif` | Ubuntu 24.04, GNOME 46, 3840×2160 at 2× scale, in a VM | GNOME Shell's own screenshot API |
| `kali-xfce-*.png` | Kali 2026.3, Xfce, 1280×800, in a VM | the VM's framebuffer (`virsh screenshot`) |

The same flows were also run and checked on Ubuntu 26.04 (GNOME 50), Debian 13 (GNOME 48) and
Debian 12 (GNOME 43 with the tray).

## What is real

- The pixels of every window, menu, dialog and icon.
- The password dialog is the system's real polkit dialog. In the throwaway VMs the test user's
  random password was typed into it as real key events through the hypervisor.
- The reminder really fired after 15 minutes ("on for 19 min" is what it said).
- The notification, tile and menu texts are Ajar's real output.

## What was scripted or edited

- Clicks were made through GNOME Shell's scripting interface (an extension that exists only
  inside the throwaway VMs puts the shell in "unsafe mode" to allow it). GNOME shows a
  padlock-with-warning icon in the top bar in that mode; it was hidden for the captures, since
  a normal desktop never shows it.
- `tools/screenshots.sh` crops, rounds the corners, adds a soft shadow, and for `hero.jpg` adds
  the dark background and the amber glow behind the real top bar.
- `demo.gif` is real key frames of one run, joined with short crossfades (the VM's virtual GPU
  cannot record video smoothly). Nothing in between frames was drawn.

## Rebuilding

The raw captures (`screenshots/raw/`) are not committed. With them in place:
`tools/screenshots.sh`. The capture helpers are in `tests/vm/`.
