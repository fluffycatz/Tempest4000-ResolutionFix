# Tempest 4000 launcher resolution list — technical notes

Target: `Tempest4000.exe`, Steam depot, 32-bit PE, MSVC 14.11 (VS2017 toolset, project still named
`Tempest4K` under a `VS2010` path in the PDB string). Two builds ship: `Win10\` (linked 2018-10-09,
`D3DCOMPILER_47`, `XINPUT1_4`, `XAudio2_8`) and `Win7-8\` (linked 2018-10-12, `D3DCOMPILER_43`,
`XINPUT1_3`). Both contain the same launcher code; every address below is for the Win10 build, the
Win7-8 build is offset by +0x90 in this region. No Steam DRM wrapper (no `.bind` section), five plain
sections, ASLR (`DYNAMIC_BASE`) with a `.reloc` table, no CFG.

Rendering is Direct3D 11 (feature level 10.0 minimum) through DXGI. There is no `EnumDisplaySettings`
import at all — display modes come only from `IDXGIOutput::GetDisplayModeList`.

## The launcher dialog

Resource `RT_DIALOG` 130 is the "Welcome to Tempest 4000" window: a `LISTBOX` (control id 2004),
*Start Game* (`IDOK`), *Configure Keyboard* (id 3, opens dialog 129), and the label
*"Use F1 to go full screen, video will be set to closest match of :"*. Its dialog procedure is at
`0x48ec60`, frame size `0x10ca8` (`__chkstk`): `0xca8` bytes of locals plus **256 × 0x100 bytes of
UTF-16 strings**, one per listbox line.

### WM_INITDIALOG — building the list

```
0x48efb7  call CreateDXGIFactory
0x48efe2  call DwmGetCompositionTimingInfo        ; desktop refresh (rateRefresh num/den)
0x48f037  call GetWindowRect(GetDesktopWindow())  ; desktop size  (not DPI-aware!)
0x48f07c  malloc(0x38) -> g_desired [0x543eb4]    ; DXGI_MODE_DESC desired @+0, copy of desktop mode @+0x1c
0x48f0e1  if prefs.w|prefs.h: desired = prefs mode (prefs+0x818..0x824)
0x48f129  factory->EnumAdapters(0)
0x48f159  adapter->EnumOutputs(i)                 ; first output whose mode list succeeds
0x48f187  output->GetDisplayModeList(DXGI_FORMAT_R8G8B8A8_UNORM, 8, &count, NULL)
0x48f1ff  g_out  [0x543f80] = malloc(count*28)    ; accepted modes (DXGI_MODE_DESC, 28 bytes each)
0x48f21c  g_list [0x543eb8] = malloc(count*28)    ; source modes
0x48f239  output->GetDisplayModeList(28, 8, &count, g_list)
```

Flags = 8 (`DXGI_ENUM_MODES_DISABLED_STEREO`); `DXGI_ENUM_MODES_SCALING` is **not** requested, so
the list has no centered/stretched duplicates — but drivers commonly return each mode twice anyway
(scanline ordering variants), and every legacy resolution at every refresh rate the display accepts.

### The loop (0x48f244 – 0x48f4fc)

```
0x48f290  cmp esi, 0x1c00        ; esi = byte offset into g_list  → stops after 256 SOURCE entries   <-- bug
0x48f296  jge done
0x48f29c  mov edi, [g_list]
0x48f2a2  ... xmm1 = (float)Numerator / (float)Denominator
0x48f2de  comiss xmm1, [50.0f]   ; refresh < 50 Hz → skip
0x48f2e5  jb   skip
          ; de-dup: same w/h as previous accepted entry, |Δrefresh| < 5.0 and refresh ≥ previous
          ; → back up one slot (dec ecx, string ptr -= 0x100, out ptr -= 28) and overwrite it
0x48f356  call floor(refresh + 0.5)
0x48f383  call swprintf_s(str[ecx], 0x100, L"%u x %u @%-d Hz", w, h, hz)
0x48f3a8  copy DXGI_MODE_DESC to g_out[edx], zero Format/ScanlineOrdering/Scaling
0x48f408  ... distance = |Δw| + |Δh| + 1000·|Δrefresh| against *desired*; track best index
0x48f4ae  inc ecx  (accepted count) ; str ptr += 0x100 ; edx += 28
0x48f4e2  skip: esi += 28 ; source index++ ; loop while index < count
```

Loop-carried state: `ecx` = accepted count (`[esp+0x10]`), `esi` = source byte offset, `edx` = output
byte offset, `[esp+0x28]` = best-match index, `[esp+0x34]`/`[esp+0x40]` = best distance, `xmm2` =
previous accepted refresh rate, `[esp+0x44]`/`[esp+0x38]` = previous accepted width/height.

After the loop: `LB_ADDSTRING` for `min(accepted, 256)` strings, `LB_SETCURSEL` to the best match,
and the selected `DXGI_MODE_DESC` is copied into the prefs (`+0x818` w, `+0x81c` h, `+0x820` num,
`+0x824` den).

### Why the cap is wrong

The 256 limit protects the string buffer (and `LB_ADDSTRING` already clamps to 256). But the number of
strings written is `ecx`, the *accepted* count, not `esi/28`. Applying the limit to the source index
means the walk quits after examining 256 raw modes — and because DXGI sorts ascending by width, height,
refresh, the entries it never reaches are precisely the high resolutions. On a typical 4K TV + modern
GPU (25 resolutions × 13 refresh rates × 2) the 256th source entry is around 1280×768, which matches
every report in the Steam threads ("max 1280×1024", "1440×900", "1600×1024", "3840×1080"…).

### Downstream (unchanged)

`WM_COMMAND/IDOK` copies `g_out[selection]` into the prefs and writes the file. At game start
(`0x490a7f`) the same entry becomes the swap-chain `BufferDesc` (`0x487db0`:
`DXGI_SWAP_CHAIN_DESC` with `Windowed = TRUE`, `Flags = DXGI_SWAP_CHAIN_FLAG_ALLOW_MODE_SWITCH`), after
`IDXGIOutput::FindClosestMatchingMode` when fullscreen is requested; F1 toggles
`IDXGISwapChain::SetFullscreenState`. No further size limits exist.

## The patch

### Part A (2 bytes)

```
0x48f290  81 fe 00 1c 00 00   cmp esi, 0x1c00
       →  81 f9 00 01 00 00   cmp ecx, 0x100
```

`ecx` is the accepted count at the loop head on every path (entry: `xor ecx,ecx`; back-edge: reloaded
from `[esp+0x10]` then `inc`; de-dup path `dec`/`inc` nets to zero; skip path leaves it untouched).
With `ecx < 256` at the head, the entry written this iteration lands in slot ≤ 255, so the buffer bound
is preserved exactly.

### Part B (hook + cave)

The 6-byte `jb skip` at `0x48f2e5` becomes `jmp cave ; nop`. The `comiss` before it is left in place
(it carries its own relocation entry for the `50.0f` constant) and its flags are still valid when the
cave starts:

```
cave:   0f 82 <rel32>       jb   skip                 ; refresh < 50 (flags from the original comiss)
        e8 00 00 00 00      call $+5
        58                  pop  eax                  ; eax = this address (whatever the load base)
        8b 80 <disp32>      mov  eax, [eax + delta]   ; delta → the disp32 field of the loop's own
                                                      ;   'mov edi,[g_desired]' at 0x48f39a; the loader
                                                      ;   has relocated it, so this yields &g_desired
        8b 00               mov  eax, [eax]           ; g_desired
        8b 40 1c            mov  eax, [eax+0x1c]      ; desktop width (pre-prefs-override copy)
        d1 e8               shr  eax, 1
        39 04 3e            cmp  [esi+edi], eax       ; mode.Width vs desktop_w/2
        0f 82 <rel32>       jb   skip
        e9 <rel32>          jmp  resume (0x48f2eb)
```

`eax` is dead at the hook point (reloaded from memory before any later use on both paths); `ecx`,
`edx`, `esi`, `edi` and all XMM registers are untouched; the `call/pop` pair is stack-neutral. Reading
the relocated pointer out of the original instruction keeps the cave position-independent, so no
relocation entries or header edits are needed. The cave sits in the zero padding between `.text`'s
`VirtualSize` and `SizeOfRawData` (`0x4af460`, 0x1a2 bytes free on the Win10 build, 0x112 on Win7-8),
which the loader maps as part of the executable section.

The filter is deliberately relative to the desktop width rather than a fixed "≥ 1920": on a 1366×768
laptop it removes nothing important, and the desktop mode itself can never be filtered out, so the list
is never empty.

### Part C (default; `-Exclusive` omits it): stay in the borderless window

The game window is created at `0x490a71` — `CreateWindowExA(0, "OVRAppWindow", …, WS_POPUP|WS_VISIBLE,
monitor.x, monitor.y, mode.w, mode.h, …)` — followed by a small struct
`{ 1, fullscreen=1, w, h, num, den }` (`0x490a8a`–`0x490afa`) that the renderer copies to `this+0xc`.
The `fullscreen` flag (`this+0x10`) gates every exclusive-mode call:

| site | code | with flag = 0 |
|---|---|---|
| `0x487dde`/`0x487e15` (swap-chain creation) | refresh from mode, `FindClosestMatchingMode` | refresh 0/1, no closest-match lookup |
| `0x487ffc` | `SetFullscreenState(TRUE, output)` after `CreateSwapChain` | `SetFullscreenState(FALSE, NULL)` (no-op) |
| `0x486a56` | `SetFullscreenState(TRUE, output)` after device init | skipped |
| `0x48b796` (teardown) | `SetFullscreenState(FALSE)` | skipped |

`DXGI_SWAP_CHAIN_DESC.Windowed` is always `TRUE` at creation and the factory gets
`MakeWindowAssociation(hwnd, DXGI_MWA_NO_WINDOW_CHANGES | DXGI_MWA_NO_ALT_ENTER)`, so nothing else can
flip the state: the runtime toggle `0x4881b0` (vtable `0x4cb798` slot 7) has no caller — F1 is not
mapped (the WndProc's `WM_KEYDOWN` only ORs the prefs key table into `[0x543f74]`, and `0x70` is
absent from it), and the `WM_SETFOCUS`/`WM_KILLFOCUS`/`WM_ACTIVATE` handlers only mute audio and
manage the cursor.

Speed correction (`0x43c740`): `GetDesc()` on the swap chain; if `!Windowed`, the time-step scale is
`60 / (BufferDesc.RefreshRate)`, otherwise `60 / DwmGetCompositionTimingInfo().rateRefresh`. Present
is `Present(1, 0)`. So in the borderless configuration pacing follows the real desktop refresh.

Part C therefore just changes the two initialisers `mov dword [ebp-0x234], 1` (`0x490a94`, `0x490ac5`;
Win7-8: `0x490b24`, `0x490b55`) to `0`. Consequence: no display-mode switch, desktop HDR state
untouched, the `WS_POPUP` window is composited by DWM as a borderless full-screen window. The window is
sized from `GetWindowRect(GetDesktopWindow())` (passed down from `0x48f824`), not from the selected
mode; the selected mode only sizes the swap-chain buffer, which the bitblt `Present` stretches to the
client area — so a lower render resolution still fills the screen.

### Prefs file

`%USERPROFILE%\Documents\Tempest4000_Savedata\Tempest4000_UserPrefs.dat`, 0x898 bytes, magic
`LE MAN SUL CUL!`, key bindings from `+0x10`, selected mode at `+0x818` (w, h, refresh numerator,
denominator as `uint32`), and a **CRC-16/XMODEM** (poly 0x1021, init 0, no reflection — table at
`0x4b8578`) over bytes `0..0x893` stored as a `uint32` at `+0x894`. The loader (`0x48ee66`) discards
the file if the CRC does not match, which is why hand-edited prefs never "took" in the 2018 threads.
`--set-mode` recomputes it.

## Verification

`tools/emu_test.py` maps the executable with unicorn (optionally relocated to another base, applying
the exe's own `.reloc` entries), points the three globals at synthetic arrays, initialises the frame
locals exactly as the real code leaves them at `0x48f244`, stubs `floor` and `swprintf_s`, and runs the
loop to `0x48f4fc`. It then reads back the string buffer, the accepted count and the best-match index.
The unpatched loop reproduces the field symptom on a 650-mode "4K TV" list (list ends at 1280×768); the
patched loop lists 3840×2160 at 50/60/100/120/144 Hz, at every base tested, on both builds.
