# MacShanti 🧘

![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)
![Platform: macOS 13+](https://img.shields.io/badge/platform-macOS%2013%2B-lightgrey.svg)
![Swift 5.9](https://img.shields.io/badge/swift-5.9-orange.svg)
![PRs welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)

**Peace of mind for your Mac's memory.**

MacShanti is a tiny app that lives in your menu bar (the strip of icons at the
top-right of your screen). It quietly keeps an eye on how much memory your Mac is
using and gives you a gentle, colored heads-up *before* things get slow — plus
one-click suggestions for which apps to close.

No windows to manage, no Dock icon, no clutter. Just a little dot that turns
green, yellow, or red.

---

## What it looks like

<!--
TODO: add a real screenshot at docs/screenshot.png, then uncomment the line below.
![MacShanti in the menu bar](docs/screenshot.png)
-->

---

## What it does for you

- 🟢🟡🔴 **A color dot in your menu bar** tells you your memory health at a glance:
  - **Green** — all good.
  - **Yellow** — getting busy.
  - **Red** — your Mac is genuinely under pressure.
- 🖱️ **Click the dot** to see how much memory is used, how much is free, and the
  **top 5 apps** eating your memory.
- 💡 **Smart suggestions** — when memory is tight, it tells you which apps to
  close to free up the most — and it's clever about it: it suggests apps you
  **haven't used in a while**, not the one you're working in right now. Each
  suggestion has a **Quit** button that does it for you.
- 🔮 **Heads-up *before* trouble** — MacShanti watches the trend of your free
  memory. If it's filling up fast, the dot turns yellow and warns you *early*
  ("about 5 min of headroom left — close an idle app now"), so you can prevent a
  slowdown instead of reacting to one.
- 🔔 **Friendly alerts** — when memory gets critical, you get a notification
  naming the biggest offenders, with **Quit**, **Snooze 30 min**, and
  **Dismiss** buttons.
- 🧠 **It learns your habits** — if you keep telling it to leave a certain app
  alone, it stops nagging you about it.
- 📊 **Daily recap** — each evening at 8pm it sends a short summary of how your
  memory behaved that day.

---

## Installing it (about 2 minutes)

You'll need a Mac running **macOS 13 (Ventura) or newer** and Apple's free
developer tools. If you've never installed those, just run this once and click
**Install** when a box pops up:

```bash
xcode-select --install
```

Then install MacShanti:

**1. Download the app.** Open the **Terminal** app and paste these two lines:

```bash
git clone https://github.com/prabhudatta-kar/macshanti.git
cd macshanti
```

**2. Build it and move it to your Applications folder:**

```bash
./Scripts/make_app.sh release
cp -R build/MacShanti.app /Applications/
```

**3. Open it:**

```bash
open /Applications/MacShanti.app
```

That's it! A colored dot appears in your menu bar.

The first time it opens, macOS will ask:
- **"MacShanti would like to send you notifications"** → click **Allow** (this is
  how you get the helpful alerts).
- It also sets itself to **open automatically when you log in**, so you never
  have to think about it again. (You can turn this off anytime — see below.)

---

## Using it

- **Check your memory:** click the dot. The popover shows everything.
- **Free up memory:** under "Recommended actions," click **Quit** next to any
  app you don't need right now.
- **Tell it to leave an app alone:** right-click any app in the list and choose
  **"Never suggest …"**. It'll stop recommending that app.
- **Snooze an alert:** when a notification appears, click **Snooze 30 min**. If
  you snooze the same app at the same time of day a couple of times, MacShanti
  takes the hint and stops bothering you then.
- **Turn off "open at login":** click the dot and uncheck **Open at login** at
  the bottom of the popover.
- **Quit the app:** click the dot → **Quit MacShanti**.

---

## A couple of common questions

**"My swap says 4 GB but the dot is green — is that a problem?"**
Nope! macOS parks unused memory on your disk ("swap") and leaves it there even
after it's no longer needed. As long as you have free memory and your Mac feels
responsive, that's completely normal. MacShanti only turns red when your Mac is
*actually* under pressure — the same signal Activity Monitor uses.

**"Does it slow down my Mac?"**
No. It takes a quick measurement every 30 seconds and otherwise sleeps. Its own
memory use is tiny.

**"Where's my data going?"**
Nowhere. Your memory data stays on your Mac in a small local file. The only
network call MacShanti ever makes is asking GitHub whether a newer version of
the app exists — it sends nothing about you or your Mac.

---

## Updating later

MacShanti checks GitHub for a new release when it launches and once a day
after that. When one is available, an **Update** button appears at the bottom
of the popover — click it and MacShanti downloads the new version, installs
it, and relaunches itself. You can also click **Check for Updates…** in the
popover anytime.

Prefer the terminal? The manual path still works:

```bash
cd macshanti
git pull
./Scripts/make_app.sh release
cp -R build/MacShanti.app /Applications/
open /Applications/MacShanti.app
```

---

## Contributing

Issues and pull requests are welcome! See **[CONTRIBUTING.md](CONTRIBUTING.md)**
for how to report a bug, suggest an idea, or send a change.

---

## For developers

Want to understand how it works or build on top of it? See
**[Developer Notes →](DEVELOPERS.md)**.

Built with Swift, SwiftUI, and [GRDB](https://github.com/groue/GRDB.swift).
Targets macOS 13+.
