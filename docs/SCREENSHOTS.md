# Screenshots to capture for ScreenInk

Capture with `Ctrl+Option+4` (region screenshot, saves to `~/Pictures/Capturas`), then move/rename the files into `docs/images/`.

General tips:
- Use a clean desktop and a neutral wallpaper. Hide the Dock and any other menu-bar icons that identify you.
- No personal data visible: no names, emails, file paths, notification banners, browser tabs or chat windows. Check the menu bar clock and the account name.
- PNG for stills; for GIFs keep them under ~8 MB (10-15 s, 800-1000 px wide).
- Light or dark mode: pick one and stay consistent across all images.

## Generated automatically

Run `./ScreenInk --render-docs docs/images` (see README, "Documentation images"). The app renders these itself, offscreen, with sample data and a synthetic background; no screenshots of a real screen are involved:

- `drawing-overlay.png`, `toolbar.png`, `spotlight.png`
- `pomodoro.png`, `pomodoro-compact.png`
- `stats.png` (invented sample history, never the real one)

## Still manual

Cannot be rendered offscreen faithfully (menu-bar items, visual-effect panel, animation). Capture with the tips above:

- [ ] `docs/images/menubar.png` - The menu-bar item and its open menu (no other personal icons).
- [ ] `docs/images/mic-indicator.png` - Menu-bar title with the red (muted) and green (active) mic light.
- [ ] `docs/images/quick-note.png` - The quick-note panel with harmless sample text.
- [ ] `docs/images/fading-strokes.gif` - 8-10 s: strokes fading by themselves.
- [ ] `docs/images/laser-trail.gif` - 5 s: laser-trail pointer moving over a slide or page.
