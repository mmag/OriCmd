# Test scripts

Debug builds of OriCmd can play keystrokes and save window snapshots (see
`OriCmd/App/DebugAutomation.swift`). These scripts drive that on throw-away
folders in `build/testdata` only — never on real files.

- `mkdata.sh` — recreates `build/testdata/{left,right}` with sample files and archives.
- `run.sh <name> "<keys>"` — launches the Debug app on the test folders, plays the
  keys (e.g. `"down space f5 wait enter"`, `cmd:cm_SyncDirs`, `click:Background`)
  and writes `build/shots/<name>.png` (plus sheets and other windows, each with a
  `.txt` of its title and texts; `menu` and `textmenu` write a context menu to
  `<name>-menu.txt`). `rightmouse:click:N`, `hold:N`, `drag:N-M` and `ctrlclick:N`
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
