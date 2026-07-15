# Thetis Level Meter

A lightweight, standalone dual VU-style level meter for [Thetis](https://github.com/ramdor/Thetis) (OpenHPSDR),
showing live RX and TX audio levels side by side. Monitoring only — nothing is recorded or encoded.

- **RX** comes straight from Thetis over the [TCI](https://github.com/ExpertSDR3/TCI) protocol
  (`audio_start` binary stream), so it shows exactly what the receiver is producing, continuously,
  regardless of transmit state.
- **TX** comes from a WASAPI capture of whatever device carries your mic audio into Thetis
  (Voicemeeter, a virtual audio cable, a direct interface — you pick it during setup).

Use it to dial in gain staging (mic chain → Thetis) before a QSO or a recording session, without
needing a full DAW or a hardware meter.

![screenshot placeholder](docs/screenshot.png)

## Requirements

- Windows 10/11
- [PowerShell 7+](https://github.com/PowerShell/PowerShell/releases) — Windows ships with 5.1 by
  default, which is **not** enough. Easiest install: `winget install Microsoft.PowerShell`, then run
  the script with `pwsh`, not `powershell.exe`.
- Thetis with the TCI server enabled: **Setup → Serial/Network/Midi CAT → Network → TCI Server**
- Internet access on first run only (downloads NAudio via NuGet)

## Getting started

1. Download `ThetisLevelMeter.ps1`.
2. If it came from a browser/email/Slack, right-click → Properties → **Unblock** (or run
   `Unblock-File .\ThetisLevelMeter.ps1` in PowerShell) — Windows flags downloaded scripts by default.
3. Run it:
   ```powershell
   pwsh .\ThetisLevelMeter.ps1
   ```
4. First run walks you through a short setup:
   - Pick which recording device carries your mic audio into Thetis, from a numbered list of
     everything Windows sees.
   - Confirm the TCI host (press Enter to auto-detect) and port (default `50001`).
   - It live-tests the TCI connection right there, so a typo or a not-yet-enabled TCI server gets
     caught immediately instead of showing up later as a blank meter.
5. That's it — every run after this is silent. To change devices or the TCI connection later:
   ```powershell
   pwsh .\ThetisLevelMeter.ps1 -Reconfigure
   ```

Setup is saved to `%APPDATA%\ThetisQSORecorder\LevelMeter.config.json`.

## Diagnostics

The script keeps a plain-text diagnostic log at
`%APPDATA%\ThetisQSORecorder\logs\LevelMeter_yyyyMMdd.log` — one file per day, auto-pruned after
5 days. It logs connection state changes, TCI reconnect attempts, RX audio gaps, and UI-thread
stalls, so an intermittent "the meter looked wrong for a second" issue can be diagnosed after the
fact instead of needing to be caught live.

## How it works, briefly

- A `System.Windows.Forms.Timer` ticks at ~25fps, draining any pending TCI WebSocket message and
  any queued WASAPI audio, computing an RMS/peak-hold value for each side, and repainting two bar
  meters.
- TCI messages are properly reassembled across WebSocket fragments (not just assumed to always
  arrive as one complete frame) before the 64-byte Thetis header is stripped off.
- If the TCI socket drops, the script retries with exponential backoff (3s → 60s cap) instead of
  requiring a restart.

## License

MIT — see [LICENSE](LICENSE).
