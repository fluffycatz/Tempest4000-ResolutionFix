# Tempest 4000 – Resolution List Fix

Fixes the Tempest 4000 (PC, Steam) launcher not offering high resolutions — 1080p, 1440p, 4K — on
modern GPUs and displays. No more editing your EDID with CRU, no driver reinstalls, no second monitor.

**Before:** the resolution list stops somewhere around 1280×768 / 1600×900 and the best you can pick is a
stretched low-res mode.
**After:** every resolution and refresh rate your display supports is listed (≥ 50 Hz, near-duplicate
refresh rates collapsed — that filtering is the game's own and unchanged). 3840×2160 @ 60 / 120 / 144 Hz
all work, and the game speed is correct at high refresh rates because Llamasoft's October 2018 patch already
fixed that — the same patch that introduced this bug.

The fix is applied to **your own** `Tempest4000.exe` (57 bytes; a backup is kept). No game files are
redistributed here.

## Quick start (Windows)

1. Download the latest release zip and extract it anywhere.
2. Exit Steam.
3. Double-click **`T4K-ResolutionFix.bat`**. It finds your Steam library, patches both
   `Win10\Tempest4000.exe` and `Win7-8\Tempest4000.exe`, and keeps `Tempest4000.exe.orig` backups.
4. Launch the game → "Play Tempest 4000 on Windows 10" → pick your mode in the list → **Start Game**.
   The choice is saved. In-game, **F1** goes fullscreen at that mode.

If the folder is not writable you will be told to run it as Administrator. If you get a Windows
SmartScreen prompt on a freshly downloaded `.bat`, choose *More info → Run anyway* — or run the
`.ps1` from a PowerShell window instead:

```powershell
powershell -ExecutionPolicy Bypass -File .\T4K-ResolutionFix.ps1
```

### Other ways to run it

| | |
|---|---|
| Report state, change nothing | `T4K-ResolutionFix.bat -Check` |
| Undo (restore the backups) | `T4K-ResolutionFix.bat -Restore` — or Steam → *Verify integrity of game files* |
| Explicit exe path(s) | `T4K-ResolutionFix.bat "C:\Program Files (x86)\Steam\steamapps\common\Tempest 4000\Win10\Tempest4000.exe"` |
| Minimal 2-byte variant only (see below) | `T4K-ResolutionFix.bat -NoCave` |
| Pre-select a mode in your prefs file (optional) | `T4K-ResolutionFix.bat -SetMode 3840x2160@60` |
| Linux / Steam Deck / macOS | `python3 t4k_resfix.py` (same options, lower-case: `--check`, `--restore`, `--no-cave`, `--set-mode 3840x2160@60`) |

The Python patcher needs no extra packages for the known Steam builds. For an unknown build
(GOG? a future re-link?) it can locate the patch sites by code signature: `pip install pefile` then
`python3 t4k_resfix.py --force <exe>` — and please open an issue with the file's SHA-256 so it can be
added to the known list.

**Steam Deck / Proton:** run the Python patcher from Desktop mode. The prefs file lives inside the Proton
prefix (`steamapps/compatdata/688140/pfx/drive_c/users/steamuser/Documents/Tempest4000_Savedata/`);
`--set-mode` finds it automatically.

Note that *Verify integrity of game files* (and any future game update) restores the original exe —
just run the patcher again.

## What the bug is

The launcher dialog enumerates display modes with `IDXGIOutput::GetDisplayModeList` and walks the
returned array to fill its listbox. The walk stops after the first **256 entries of the source array**:

```
0x48f290  81 fe 00 1c 00 00   cmp esi, 0x1c00      ; esi = byte offset; 0x1c00 / sizeof(DXGI_MODE_DESC)=28 → 256
0x48f296  0f 8d 60 02 00 00   jge <done>
```

That limit exists to protect a 256-entry string buffer on the stack — but it is applied to the *input*
index rather than to the number of *accepted* entries. DXGI returns modes sorted ascending by
width/height/refresh, so as soon as a display + GPU report more than 256 modes (a 4K TV over HDMI 2.1
on a current NVIDIA/AMD card reports 600+: every legacy resolution × every refresh rate, most of them
twice), the high-resolution end of the list is simply never looked at. Everything after the launcher —
prefs storage, `FindClosestMatchingMode`, swap-chain creation, `SetFullscreenState` — handles any mode
fine.

This is exactly what Llamasoft's Giles suspected in the [Steam thread](https://steamcommunity.com/app/688140/discussions/0/3047230768364098880)
("*unless maybe your video card has a ton and a half of video modes I ran out of space to fill up my list*")
and why deleting EDID timings with CRU worked around it.

## What the patch does

**Part A — 2 bytes.** `cmp esi, 0x1c00` → `cmp ecx, 0x100`: the cap now applies to the accepted-entry
count (`ecx`), which is what the buffer size actually constrains. Nothing can overflow that was not
already bounded, and the `LB_ADDSTRING` loop after the walk was already `min(count, 256)`.

**Part B — 6-byte hook + 39-byte code cave (default on).** Belt-and-braces for systems that would still
produce more than 256 *accepted* modes: the launcher's own `refresh ≥ 50 Hz` test is extended with
`width ≥ desktop_width / 2` (using the desktop size the game itself measured), so the 256 slots are spent
on the useful end of the list. The desktop mode always passes, so the list can never be empty even on
a small laptop panel. The cave lives in the zero padding at the end of `.text` and is position-independent
(the exe is ASLR-enabled). `-NoCave` / `--no-cave` applies Part A only.

Full disassembly, the prefs-file format (including its CRC-16), and how the patch was verified by
emulating the game's own loop code: [docs/TECHNICAL.md](docs/TECHNICAL.md).

## Supported builds

| Launch option | Link date | SHA-256 of original `Tempest4000.exe` | after patch |
|---|---|---|---|
| Play Tempest 4000 on Windows 10 (`Win10\`) | 2018-10-09 | `591fa012 82c4a62e aed8583d ac845c36 9d9330e7 e5052e95 856b80c8 eba2fb1a` | `46e82e75…d01f6e` |
| Play Tempest 4000 on Windows 7 or 8 (`Win7-8\`) | 2018-10-12 | `411aa66a b702b21c 4e0949e4 049b486a eb883257 86c3f6d1 4a853888 058a9b9b` | `e143b845…78b0a` |

These are the current Steam depot files (unchanged since 2018). Any other file is refused untouched.

## Verification

`tools/emu_test.py` runs the real x86 code of the launcher's mode loop under
[unicorn](https://www.unicorn-engine.org/) against synthetic DXGI mode lists, at several load bases
(ASLR), for original and patched executables:

```
$ python3 tools/emu_test.py Tempest4000.exe            # original
  4K/144 TV, 25 res x 13 Hz, duplicated   src= 650 accepted= 49 4K@60=False default=1280 x 768 @60 Hz
  stress: 70 res x 13 Hz, duplicated      src=1768 accepted= 49 4K@60=False default=720 x 576 @60 Hz
$ python3 tools/emu_test.py Tempest4000.exe            # patched
  4K/144 TV, 25 res x 13 Hz, duplicated   src= 650 accepted= 25 4K@60=True  default=3840 x 2160 @60 Hz
  stress: 70 res x 13 Hz, duplicated      src=1768 accepted=145 4K@60=True  default=3840 x 2160 @60 Hz
  1366x768 laptop, 5 modes                src=   5 accepted=  4 4K@60=False default=1366 x 768 @60 Hz
```

Confirmed on real hardware: RTX 5090 + LG G3 (HDMI 2.1), 3840×2160 at 60 and 144 Hz.

## FAQ

**Is this safe / a "crack"?** No DRM is involved — the Steam build is not wrapped — and the patch does
not touch anything except the launcher's mode-list loop. Steam still runs the game normally.

**The list shows 50 Hz, 60 Hz, 100 Hz … but not 59.94 Hz.** That is the game's own de-duplication
(refresh rates within 5 Hz of the previous entry for the same resolution are merged, keeping the higher
one). Unchanged by this patch.

**The default selection is odd at first launch.** The launcher pre-selects the closest match to the mode
stored in your prefs (or to the desktop size, which it measures without DPI awareness). Pick the mode you
want once; it is remembered. Or use `-SetMode`.

**Can this be fixed upstream?** Yes, trivially — Part A is a one-register change in the launcher's
loop. Llamasoft/Atari are welcome to it.

## Credits

* Giles (gilesgoat) of Llamasoft, for describing the list-capacity problem on the Steam forum.
* DrFluffyCatz — the original CRU/EDID workaround (2024), testing, and publication of this fix.
* Reverse engineering, patch design and emulation testing done with Claude (Anthropic).

## License

MIT — see [LICENSE](LICENSE). Tempest 4000 is © Atari / Llamasoft; this project contains no game
files or code.
