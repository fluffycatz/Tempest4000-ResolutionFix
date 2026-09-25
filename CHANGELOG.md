# Changelog

## 1.0.0 — 2026-09-25

First release.

* Part A: cap the launcher's mode walk on accepted entries instead of source entries (the actual bug).
* Part B: position-independent code cave adding a `width >= desktop_width/2` filter so pathological
  mode lists cannot crowd out high resolutions.
* Windows patcher (`T4K-ResolutionFix.bat` / `.ps1`, no dependencies) and cross-platform Python patcher
  (`t4k_resfix.py`) with `--check`, `--restore`, `--no-cave`, `--set-mode`.
* Supports both Steam builds (`Win10\` 2018-10-09 and `Win7-8\` 2018-10-12).
* Emulation test harness (`tools/emu_test.py`).
