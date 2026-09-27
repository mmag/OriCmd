# Test scripts

Debug builds of OriCmd can play keystrokes and save window snapshots (see
`OriCmd/App/DebugAutomation.swift`). These scripts drive that on throw-away
folders in `build/testdata` only — never on real files.

- `mkdata.sh` — recreates `build/testdata/{left,right}` with sample files and archives.
- `run.sh <name> "<keys>"` — launches the Debug app on the test folders, plays the
  keys (e.g. `"down space f5 wait enter"`, `cmd:cm_SyncDirs`, `click:Background`)
  and writes `build/shots/<name>.png` (plus sheets and other windows).
- `regress.sh` — plays the main file operations and checks the results on disk.
- `loc.py [translations.json]` — lists localization keys missing from the catalog,
  or adds Russian translations from a JSON file.

Build the Debug app first (`xcodebuild … -derivedDataPath build/DerivedData build`).
