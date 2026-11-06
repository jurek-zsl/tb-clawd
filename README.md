# Clawd for your Touch Bar

A little Clawd, running alongside your work.

![Clawd running across a black Touch Bar strip](docs/assets/preview.gif)

A native [Pock](https://pock.app) widget with the Claude Code mascot's flat pixel
body, square eyes and four little legs. He runs across the available Touch Bar
space, stops to code, sips coffee, stretches with a yawn, and curls up for a
nap. Poke Clawd himself and he throws a tiny 2.5 second tantrum before returning
to exactly what he was doing. Tapping the empty bar or his props does nothing.

**macOS 11+ · Pock 0.9 · Intel + Apple Silicon · no runtime dependencies**

## Install

**Version 1.2.1** adds autonomous coding, coffee, stretching and naps, plus
actor-only mad reactions and direct Touch Bar input.
Finger taps use Clawd's horizontal span because Touch Bar touch geometry only
provides a meaningful horizontal coordinate. Empty space still ignores taps.

1. Download **[Clawd.pock.zip from the latest release](https://github.com/jurek-zsl/tb-clawd/releases/latest)** and unzip it.
2. Open the extracted **Clawd.pock** bundle with Pock and follow its installation prompt.
3. Quit and reopen Pock, choose **Customize Pock…** from its menu bar menu, and drag **Clawd** onto your Touch Bar.

If opening the bundle does not launch Pock's installer, put `Clawd.pock` in
`~/Library/Application Support/Pock/Widgets/`, then reopen Pock. The release is
ad-hoc signed, not notarized; macOS may request approval when downloaded.

Clawd yields space to your other widgets, with a 64 point minimum. For the
whole bar, remove other widgets in Customize Pock and enable Pock's **Full
Width** layout if needed. Pock determines the final available width; the widget
does not change your layout or preferences.

To uninstall, quit Pock and remove `Clawd.pock` from that Widgets folder.

## Build from source

Requires Xcode command line tools. Pock is needed for the compatibility checks.

```sh
git clone https://github.com/jurek-zsl/tb-clawd.git
cd tb-clawd
./build.sh
./check.sh
./install.sh
```

The universal bundle is built at `dist/Clawd.pock`; `dist/Clawd.pock.zip` is ready
to share. `install.sh` installs only this widget and preserves an existing copy
with the same identifier as a timestamped backup. It refuses to replace an
unrelated bundle. Reopen Pock after installing an update.

## Preview the little runner

```sh
./build/pock/ClawdTools --preview
```

The resizable native window uses the actual widget renderer and works on Macs
without a Touch Bar. Resize it to see Clawd adapt to the available space, and
poke the character to see his reaction.

![Actual coding, coffee, stretch, nap and mad poses](docs/assets/actions-contact.png)

![Clawd getting briefly mad when poked](docs/assets/mad.gif)

A deterministic schedule alternates four journeys with coding (10 seconds),
coffee (8 seconds), stretching (6 seconds), and napping (10 seconds). Each action
has a setup, held main action, and recovery: opening/typing/closing the laptop,
lifting/sipping/lowering the cup, gathering/stretching/yawning, and settling/
breathing/waking. Props stay attached and point toward the bar interior.

A direct poke pauses this schedule at Clawd's current location. His angry brows,
shaking, hands on hips and little steam puff settle before the original action
resumes. Repeated pokes restart the reaction without moving him or advancing the
paused activity. The accessibility press action targets Clawd as well.

Clawd runs at 64 points per second with gentle acceleration at each end; his
leg cadence follows distance travelled. A 30 fps timer runs while the widget
is visible and pauses on removal, sleep, inactive user session or app hiding.

To regenerate previews, Pillow is an optional development dependency:

```sh
./build/pock/ClawdTools --export build/pock/frames-v1.2 685
./build/pock/ClawdTools --poses build/pock/poses-v1.2 176
./build/pock/ClawdTools --reaction build/pock/reaction-v1.2 176
python3 -m venv build/pock/preview-venv
build/pock/preview-venv/bin/python -m pip install Pillow
build/pock/preview-venv/bin/python Tools/make_preview.py
```

Export records the complete activity schedule along a 685 point strip. Add a width argument,
such as `--export build/pock/frames-1000 1000`, to capture another allocation.
The Python script assembles AppKit-rendered PNGs into `dist/Clawd-preview.gif`
(full width), `Clawd-actions.gif` (a closer view), `Clawd-mad.gif`, and the labelled
`Clawd-actions-contact.png`. Labels are outside the widget in the review sheet;
the Touch Bar itself shows only Clawd and his props.

## Verification

`check.sh` loads the installed PockKit framework first, then checks the bundle's
principal class against its real `PKWidget` protocol. It verifies native layout
at widths 64, 176, 685 and 1000, complete travel, rendered bounds, stable running
speed, all four activities, continuous endpoint transitions, actor-only hits,
mad freeze/resume and repeated pokes, exact entry/recovery pixels, direct Touch
Bar handler dispatch using test events, indirect/empty/prop filtering, duplicate
mouse suppression, customization, lifecycle, sleep/wake, accessibility, object release,
both CPU architectures and code signing. Set `POCK_APP` if Pock is installed
outside `/Applications`. Physical Touch Bar presentation still needs a Touch
Bar Mac.

## Credits

Originally developed in [claudefm](https://github.com/jurek-zsl/claudefm).
Claude and Clawd belong to Anthropic; this is an unaffiliated community widget
with original code-drawn artwork, informed by the
[Claude Code storefront mascot](https://www.stickermule.com/claudecode/item/19156131).

Built against the public [PockKit widget protocol](https://github.com/pock/pockkit/blob/master/PockKit/Sources/Protocols/PKWidget.swift).
Pock supplies its own framework at runtime; no duplicate framework is bundled.
See [LICENSE](LICENSE), [NOTICE](NOTICE) and
[third-party notices](THIRD_PARTY_NOTICES.md).
