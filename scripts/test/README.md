# Test scripts

Debug builds of OriCmd can play keystrokes and save window snapshots (see
`OriCmd/App/DebugAutomation.swift`). These scripts drive that on throw-away
folders in `build/testdata` only — never on real files. A test run starts in the
background and never takes the focus (`open -g`, no activation), and it ignores the
real keyboard and mouse, so working elsewhere meanwhile changes nothing.

- `mkdata.sh` — recreates `build/testdata/{left,right}` with sample files and archives.
- `run.sh <name> "<keys>"` — launches the Debug app on the test folders, plays the
  keys (e.g. `"down space f5 wait enter"`, `cmd:cm_SyncDirs`, `click:Background`)
  and writes `build/shots/<name>.png` (plus sheets and other windows, each with a
  `.txt` of its title and texts, and for a text view `[text colors: N]`; `menu` and
  `textmenu` write a context menu to `<name>-menu.txt`). In the Lister of a Debug
  build, test extensions drive the highlighting service: `*.oricmdhang` makes it hang
  (it must be killed), `*.oricmdexit` makes it quit, `*.oricmdoverlap` makes it reply
  overlapping ranges or `*.oricmdlongscope` a huge scope name (OriCmd must refuse
  both), `*.oricmdfiles` / `*.oricmdlookup` / `*.oricmdprefs` ask it to read the
  file / reach the service / write the preferences domain named inside (it must be
  refused); `<name>-highlighter.txt` counts the services killed and the texts sent. `rightmouse:click:N`, `hold:N`, `drag:N-M` and `ctrlclick:N`
  play the right button on panel rows.
  Modifiers: `cmd+`, `shift+`, `alt+`, `ctrl+`, `num+`; `ru+` types the key as the
  Russian layout would (`ru+ctrl+d` sends "в" with the D key code).
- `regress.sh` — plays the main file operations and checks the results on disk.
- `../screenshots.sh` — regenerates the README screenshots (`docs/screenshots/{en,ru}`) on demo
  folders from `../mkdemo.sh`; `ORICMD_DEMO=1` hides all volumes but the startup disk.
  Test runs never use or change the saved window frames.
- `loc.py [translations.json]` — lists localization keys missing from the catalog,
  or adds Russian translations from a JSON file.

Build the Debug app first (`xcodebuild … -derivedDataPath build/DerivedData build`).
