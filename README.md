# claude-code-tts

Makes [Claude Code](https://claude.com/claude-code) read its answers aloud on Windows.

- **Natural online voice** via [edge-tts](https://github.com/rany2/edge-tts), with an
  **automatic fallback** to an offline Windows voice when there is no internet, no Python,
  or the service does not answer within 10 seconds.
- Reads the **prose** of each answer: code blocks and long paths are skipped, table rows
  are read as sentences, headings and list items get a short pause.
- **Stops by itself** when you send the next message, or anytime with **Ctrl+Alt+S**.
- **Reads the last answer again** with **Ctrl+Alt+R**, and turns read-aloud **on or off**
  with **Ctrl+Alt+T** (a short spoken "on"/"off" confirms it).
- Starts speaking about 2 seconds after the answer is finished (first sentence is
  synthesized separately, the rest is prepared while it plays).

## Install

Open PowerShell (no admin rights needed) and run:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/spyrad/claude-code-tts/main/install.ps1)))
```

Or download [`install.cmd`](install.cmd) and double-click it.

Then open `/hooks` once in Claude Code (or restart it). You will hear a short test sentence
at the end of the installation.

**Requirements:** Windows 10/11, Windows PowerShell 5.1 (built in), Claude Code.
Python 3.9+ for the online voice - without it the offline voice is used.

## Options

Append options to the one-liner (or to `install.cmd`):

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/spyrad/claude-code-tts/main/install.ps1))) -Voice en-GB-SoniaNeural
```

| Option | Effect |
|--------|--------|
| `-Voice <name>` | Online voice, e.g. `en-US-AriaNeural`, `en-GB-SoniaNeural`, `de-DE-KatjaNeural`. Default: English, or German if Windows runs in German. List all voices: `python -m edge_tts --list-voices` |
| `-FallbackVoice <name>` | Offline Windows voice, e.g. `"Microsoft Zira Desktop"`. Default: a voice matching the language of `-Voice` |
| `-OfflineOnly` | Windows voice only - no Python, **nothing is sent to an online service** |
| `-StopHotkey <keys>` | Hotkey that stops the speech, default `CTRL+ALT+S` |
| `-ReplayHotkey <keys>` | Hotkey that reads the last answer again, default `CTRL+ALT+R` |
| `-ToggleHotkey <keys>` | Hotkey that turns read-aloud on or off, default `CTRL+ALT+T` |
| `-NoHotkey` | Do not create any hotkey |
| `-NoTest` | No test sentence at the end |
| `-Uninstall` | Remove everything again (see below) |

The installer is safe to run repeatedly. It backs up `settings.json` before changing it
and leaves all your other settings and hooks alone.

## Usage

| What | How |
|------|-----|
| Stop the current speech | **Ctrl+Alt+S** (any window), or just send your next message |
| Read the last answer again | **Ctrl+Alt+R** - also works while read-aloud is off |
| Turn read-aloud off / on | **Ctrl+Alt+T** - you hear "Read-aloud off" / "Read-aloud on". Without the hotkey: create / delete the empty file `%USERPROFILE%\.claude\tts-off` |
| Change voice or speed | edit `%USERPROFILE%\.claude\tts\voice.json` - applies to the next answer |

While read-aloud is off, answers are still remembered, so you can switch it off for good and
press Ctrl+Alt+R only for the answers you want to hear.

Prefer a button? The three hotkeys are Start menu shortcuts (`Claude stop reading`,
`Claude read again`, `Claude read-aloud on-off`) - pin them to the taskbar or Start.

`voice.json`:

```json
{
  "engine": "edge",
  "edgeVoice": "en-US-AriaNeural",
  "edgeRate": "+0%",
  "sapiVoice": "Microsoft Zira Desktop",
  "sapiRate": 1
}
```

`engine` is `edge` (online first, offline fallback) or `sapi` (offline only).
`edgeRate` like `+10%` / `-10%`, `sapiRate` from `-10` to `10`.

## Privacy

With the online voice, the text that is read aloud is sent to Microsoft's speech service
(the same one the Edge browser uses for "Read aloud"). Code blocks are removed first, but
the prose of Claude's answers leaves your machine. If that is not acceptable - for example
with confidential work - install with `-OfflineOnly`.

## How it works

The installer adds two [hooks](https://docs.claude.com/en/docs/claude-code/hooks) to
`%USERPROFILE%\.claude\settings.json`:

- **Stop** - after every answer, `hooks\speak-last-answer.ps1` turns the answer into
  speakable text and hands it to a hidden background process, so Claude Code is never blocked.
- **UserPromptSubmit** - when you send a message, the running speech is stopped.

Files it creates:

```
%USERPROFILE%\.claude\hooks\speak-last-answer.ps1   hook script
%USERPROFILE%\.claude\tts\voice.json                 voice settings
%USERPROFILE%\.claude\tts\edge_say.py                edge-tts wrapper
%USERPROFILE%\.claude\tts\ca-bundle.pem              certificate bundle (see below)
%USERPROFILE%\.claude\tts\python-path.txt            Python found by the installer
Start menu\Programs\Claude stop reading.lnk          stop hotkey
Start menu\Programs\Claude read again.lnk            replay hotkey
Start menu\Programs\Claude read-aloud on-off.lnk     on/off hotkey
%TEMP%\claude-tts\last.txt                           text of the last answer, for replay
```

**Certificate bundle:** antivirus products with HTTPS scanning and many corporate proxies
re-sign TLS traffic. edge-tts only trusts Python's certifi bundle and fails in that case.
The installer builds `ca-bundle.pem` from certifi plus the root certificates your Windows
already trusts, so it works behind such setups without disabling anything.

## Uninstall

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/spyrad/claude-code-tts/main/install.ps1))) -Uninstall
```

Removes both hooks from `settings.json` (with a backup), the files above and the shortcuts.
The Python package stays; remove it with `python -m pip uninstall edge-tts`.

## Troubleshooting

- **Nothing is read:** open `/hooks` in Claude Code once or restart it. Check that
  `%USERPROFILE%\.claude\tts-off` does not exist.
- **Always the robotic voice:** the online voice failed. See the log
  `%TEMP%\claude-tts\speak.log` - `fallback sapi` lines tell why. Common causes: no
  internet, a proxy that needs a login, or Python missing.
- **A hotkey does nothing:** another program uses the same keys. Re-run the installer
  with e.g. `-StopHotkey CTRL+ALT+Q` (or `-ReplayHotkey` / `-ToggleHotkey`); it warns about
  clashes it can see.
- **"running scripts is disabled":** your organization blocks PowerShell scripts by policy;
  `-ExecutionPolicy Bypass` cannot override that.

## Development

`install.ps1` is generated - edit the files in `src/` and rebuild:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File build.ps1
```

`build.ps1` embeds `src/speak-last-answer.ps1` and `src/edge_say.py` into
`src/install-template.ps1` and checks that the result is ASCII-only and parses.

## License

[MIT](LICENSE)
