# OriCmd

**English** | [Русский](README.ru.md)

A two-panel file manager for macOS with a familiar look: two panels, function
key buttons at the bottom, a command line and full keyboard control — everything
in its usual place. The standard macOS shortcuts (`⌘C`, `⌘V`, `⌘Q`, `⌘W`, …)
keep working as always.

![OriCmd main window](docs/screenshots/en/main.png)

## Features

- **Panels:** tabs, history, directory hotlist, tree, filters, quick search;
  full and brief views, thumbnails, optional columns, file colors by mask.
- **Copy and move:** queue and background operations, file type filter, name
  masks, overwrite modes, verification after copying.
- **Archives as folders:** zip, tar, 7z and more — browse, extract, pack and
  change files right inside an archive.
- **Servers in a panel:** SFTP (through the system ssh, with keys and
  passwords) with the server's terminal under the files, FTP/FTPS, saved
  connections; smb, afp, NFS and WebDAV as volumes.
- **Tools:** text, hex and Quick Look viewer (`F3`), compare files by content,
  synchronize directories, multi-rename, find files, checksums, attributes.
- **Make it yours:** your own keyboard shortcuts (including import from
  `wincmd.ini`), a Start menu, programs for `Enter`/`F3`/`F4` by file mask, a
  customizable button bar.
- Light and dark themes, English and Russian interface, automatic updates from GitHub.

## Screenshots

| | |
|---|---|
| ![Copy dialog](docs/screenshots/en/copy-dialog.png)<br>Copy (`F5`): file type filter, name masks, overwrite modes | ![Settings](docs/screenshots/en/settings.png)<br>Settings with a panel preview |
| ![Compare by content](docs/screenshots/en/compare.png)<br>Compare files by content | ![Multi-Rename Tool](docs/screenshots/en/multi-rename.png)<br>Multi-Rename Tool (`Ctrl+M`) |
| ![Synchronize directories](docs/screenshots/en/sync.png)<br>Synchronize directories | ![Dark theme](docs/screenshots/en/main-dark.png)<br>Dark theme |

The screenshots are made by `scripts/screenshots.sh` on demo folders
(English ones in `docs/screenshots/en`, Russian ones in `docs/screenshots/ru`).

## Installation

With [Homebrew](https://brew.sh):

```sh
brew install --cask mmag/tap/oricmd
```

Or download the disk image from the [Releases](https://github.com/mmag/OriCmd/releases)
page. You can also build one yourself (a universal app for Apple Silicon and
Intel, macOS 14+):

```sh
scripts/make-dmg.sh        # → build/OriCmd-<version>.dmg
```

Open the image and drag OriCmd to Applications. The app is ad-hoc signed,
without an Apple certificate, so macOS won't open it the first time (whether it
came from Homebrew or from the image): right-click
OriCmd → Open → Open (or System Settings → Privacy & Security → Open Anyway).
Or remove the quarantine:

```sh
xattr -dr com.apple.quarantine /Applications/OriCmd.app
```

After that OriCmd updates itself: once a day (can be turned off in Settings) and
with OriCmd → Check for Updates… it looks for the latest release on GitHub,
downloads the image, replaces the app and relaunches. Updates are not
quarantined, so there is no need to allow the app again.

## Building

Requires macOS 14+ and Xcode.

```sh
xcodebuild -project OriCmd.xcodeproj -scheme OriCmd -configuration Debug build
```

The terminal is [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) (a Swift
package; Xcode fetches it on the first build).

The icon is drawn by `swift scripts/make-icon.swift`.

## Keys

On a Mac the F keys control brightness, sound and so on by default. Press them
with `fn`, or turn on "Use F1, F2, etc. keys as standard function keys" in
System Settings → Keyboard.

Commands have internal names (`cm_Copy`, `cm_RenMov`, …) compatible with
`wincmd.ini`; all of them are in the menus. Shortcuts in parentheses are
additional Mac-style ones.

Shortcuts are bound to physical keys: with a Russian (or any other) keyboard
layout `Ctrl+D`, `Ctrl+B`, `Ctrl+U` etc. work just like with the English one.

### Panels and navigation

| Key | Action |
|---|---|
| `↑` `↓` `PgUp` `PgDn` `Home` `End` | Move the cursor |
| `Enter`, double-click (`⌘↓`) | Open a folder / open a file |
| `Backspace`, `Ctrl+PgUp` (`⌘↑`) | Parent folder |
| `Ctrl+PgDn` | Go inside a package (`.app` etc.) |
| `Tab` | Switch panels |
| `Alt+←` / `Alt+→` (`⌘[` / `⌘]`) | Back / forward in the folder history |
| `Alt+↓` | Recent folders |
| `Ctrl+←` / `Ctrl+→` (`⌥⌘←` / `⌥⌘→`) | Show the folder under the cursor in the left / right panel |
| `Alt+F1` / `Alt+F2` | Volume list of the left / right panel |
| `Ctrl+\` | Root of the volume |
| `⌘T` / `⌘W` | New tab / close tab |
| `Ctrl+Tab` / `Ctrl+Shift+Tab` (`⇧⌘]` / `⇧⌘[`) | Next / previous tab |
| `Ctrl+↑` (`⌥⌘↑`) | Open the folder under the cursor in a new tab |
| `Ctrl+D` (`⌘D`) | Directory hotlist: go, add or remove the current folder |
| `Alt`+letter, `Ctrl+Alt`+letter | Quick search by name (`↑`/`↓` — other matches, a leading `*` searches inside names) |
| `Alt+F7` (`⌘F`) | Find files by mask and text; "Feed to Panel" shows the results as a list in the panel, where all commands work on them, `[..]` returns to the search folder |
| `Ctrl+F1` / `Ctrl+F2` (`⌘1` / `⌘2`) | Brief / Full view |
| `Ctrl+Shift+F1` (`⌘4`) | Thumbnails (Quick Look previews) |
| Right-click on the column headers | Optional columns: kind, date created, picture dimensions, duration, Finder tags (sortable like the others) |
| `Ctrl+F8` (`⌘3`) | Directory tree; the other panel shows the chosen folder |
| `Shift+F2` | Compare directories: mark unique and newer files in both panels |
| Commands → Synchronous Directory Changes | Entering a subfolder or going up in one panel is repeated in the other (if it has such a folder) |
| Commands → Synchronize Directories… | Compare two folders recursively and copy in the chosen directions (double-click or `Space` changes the direction) |
| `Ctrl+U` | Swap panels |
| Commands → Left = Right / Right = Left | Show the folder of one panel in the other |
| `⌘R` (`Ctrl+R`) | Reread the folder (changes are also picked up automatically) |
| `⇧⌘.` | Show / hide hidden files |
| `Ctrl+F3` … `Ctrl+F6` (`⌃⌥⌘1` … `⌃⌥⌘4`) | Sort by name, extension, date, size; again — reverse order. Clicking a column header does the same |

`Ctrl+F1`…`Ctrl+F8`, `Ctrl+↑` and `Ctrl+←/→` are taken by macOS by default
(focus on the Dock and the menu bar, Mission Control, switching Spaces). Turn
them off in System Settings → Keyboard → Keyboard Shortcuts, or use the
shortcuts in parentheses.

### Selection

| Key | Action |
|---|---|
| `Space`, `Insert` | Mark a file and move down; on a folder, also calculate its size |
| `Alt+Shift+Enter` | Calculate the size of all folders |
| `Shift+↑/↓`, `Shift+PgUp/PgDn/Home/End` | Mark a range |
| `⌘`-click, `Shift`-click | Mark with the mouse |
| `+` / `−` | Mark / unmark a group by mask (`*.txt;*.md`) |
| `*` | Invert the marking of files |
| `Num /` | Restore the previous selection |
| `⌘A` / `⌥⌘A` | Mark all / unmark all |
| `⌥+` / `⌥−` | Mark / unmark files with the extension of the one under the cursor |
| Show → Filter… | Show only files matching a mask (the mask is shown in the path bar) |
| `Ctrl+B` (`⌘B`) | Branch view: all files of the folder and its subfolders in one list |
| `Ctrl+S` | Quick filter: only names containing the typed text stay; `Enter` keeps the filter, `Esc` removes it |

### File operations

| Key | Action |
|---|---|
| `F3` | View (Lister): `1` text, `3` hex, `7` Quick Look, `W` word wrap, `N`/`P` next/previous file, `F7`/`⌘F` find, `F3`/`⇧F3` find next/previous, `Esc` close |
| `F4` | Open in the default text editor (or the program from the associations) |
| `Shift+F4` | Create a new file and open it in the editor |
| `F5` | Copy (to the other panel by default) |
| `Shift+F5` | Copy within the same folder under another name |
| `F6` | Move / rename |
| `Shift+F6` | Rename in place |
| `Ctrl+M` | Multi-Rename Tool: masks `[N]`, `[N2-5]`, `[E]`, `[C]`, `[P]`, `[YMD]`, `[hms]`, search and replace (including regular expressions), case, preview and undo |
| `F7` (`⇧⌘N`) | New folder (`a/b/c` creates nested ones) |
| `F8`, `Del` (`⌘⌫`) | Move to the Trash |
| `Shift+F8`, `Shift+Del` | Delete permanently |
| `Ctrl+Shift+F5` | Create a symbolic link (in the other panel by default) |
| Files → Compare by Content | Two marked files, or the files under the cursors of both panels. The compare window aligns the lines: changed ones are yellow (with the differing part highlighted), removed ones red, added ones green; `N`/`P` (`⌥↓`/`⌥↑`) — next/previous difference, "Ignore whitespace"; binary files are compared byte by byte in hex |
| `⌘I` | Change attributes: rwx permissions, hidden, locked, modification date (also recursively) |
| `Ctrl+Q` | Quick View in the other panel |
| `⌘C` / `⌘X` / `⌘V` (`Ctrl+C` / `Ctrl+X` / `Ctrl+V`) | Copy / cut / paste files (compatible with Finder); pasting into the same folder creates "name copy" |
| `⌥⌘V` | Move the files from the clipboard here |
| `⌥⌘C` | Copy the full paths of the selected files (Mark → Copy Names — names only) |
| `⌘K` | Connect to a server: `sftp://`, `ftp://`, `ftps://`, `ftpes://` open right in the panel; smb, afp, nfs and WebDAV are mounted as volumes |
| `Ctrl+F` (`⇧⌘K`) | Saved connections (passwords are kept in the Keychain) |
| Net → Disconnect | Close the server in the active panel |
| `⌘E` | Eject the removable or network volume of the active panel |
| `Alt+F5` | Pack into an archive (the format follows the extension: `.zip`, `.tar.gz`, `.tar.bz2`, `.tar.xz`, `.7z`) |
| `Alt+F9` | Unpack the selected archives |
| Files → Create Checksum File… | MD5 / SHA-1 / SHA-256 / SHA-512 for the selection (`shasum`/`md5sum` format) |
| Files → Verify Checksums | Check the `.md5`/`.sha1`/`.sha256`/`.sha512` file under the cursor |

Long operations (copy, move, archives) show their progress; the "Background"
button moves it to a separate window so you can keep working with the panels.

#### The copy and move dialog (`F5` / `F6`)

- **Target** with a name mask: `folder/*.*` keeps the names, `folder/*.bak`
  changes the extension, `folder/new_*.*` adds a prefix; without a mask and for a
  single file it is the new name. The drop-down list holds the target list and
  recent paths; `F7` (the "+ F7" button) adds the current folder to the target
  list or removes it, `⌃D` picks a folder from the directory hotlist, "Tree"
  chooses a folder.
- **Only files of this type:** `*.jpg *.png` copies only such files (in
  subfolders too); exclusions come after `|`: `*.* | *.bak .git/ node_modules/`;
  a name ending in `/` is a folder at any depth (`src/` — only the `src` folders,
  with everything inside). Folders left empty by the filter are not created.
  `F8` (the "+ F8" button) — saved filters and examples.
- **Copy extended attributes and ACLs** (tags, Finder comments, access
  rights); **Verify** compares every copied file with the original.
- Buttons: **OK** (`Return`), **F2 Queue** — the operation joins the queue and
  runs one at a time in its own progress window, **Tree**, **Cancel** (`Esc`),
  **Options >>**. Right-click OK or F2 Queue to move instead of copying (and the
  other way round).
- **Options >>**: overwrite mode (ask, overwrite all, skip all, overwrite older,
  auto-rename the copied or the existing files — `name(2).ext`, copy larger or
  smaller ones), skip unreadable files, overwrite/delete locked files, copy to all
  folders selected in the target panel. The pin keeps the options open, the save
  button makes them the default.

### Archives

`Enter` or `Ctrl+PgDn` on an archive (zip, tar.\*, 7z, rar, iso, cab, …) opens
it like a folder. Inside it navigation, selection, `F3`, `Enter` (the file is
extracted to a temporary folder and opened) and `F5` (extract the selection to
the other panel) work. Zip, tar, tar.gz, tar.bz2, tar.xz and 7z archives can
also be written: `F5`/`F6` into a panel showing an archive pack the files into
it, and `F7`, `F8` and `Shift+F6` work inside (the archive is rebuilt through a
temporary folder). rar, iso, cab and others are read-only.

### Button bar and drive buttons

Under the window title there is a button bar with frequent commands (reread,
views, history, hotlist, find, multi-rename, synchronize, archives, Terminal).
Right-click it → Customize Toolbar… to change it. Applications can go on it too:
drag an `.app` from Finder or from a panel onto the button bar (or right-click an
application → Add to Button Bar). A click on its button starts the application,
files dropped on the button open in it; right-click for Show in Finder and Remove
from Button Bar. Above each panel there are
drive buttons: the startup volume, the home folder and mounted volumes (can be
hidden in Settings).

### Servers (SFTP, FTP)

SFTP works through the system `ssh`/`sftp`: `~/.ssh/config` (aliases,
ProxyJump), keys and ssh-agent are used; there is one shared connection per
server, and a password or passphrase is asked for once. FTP/FTPS goes through the
system `curl`. On a server navigation, `F3`, `Enter`, `F5`/`F6` both ways
(download/upload), `F7`, `F8`, `Shift+F6`, paste from the clipboard and dropping
files onto the server panel work. Transfers go file by file with byte progress
(current file and total). SFTP keeps permissions and dates of files and folders,
FTP keeps the dates of downloaded files.

#### Server terminal

An SFTP panel is split in two: the files on top, the server's shell below, opened
in the panel's folder over the same connection (nothing is asked again). Drag
the line above the terminal to resize it.

| Key | Action |
|---|---|
| `` ⌃` `` | Go to the terminal (showing it); in the terminal, hide it and go back to the files |
| `` ⌃⌥` `` | Type `cd` to the panel's folder into the terminal |

While the terminal has the focus, every key without `⌘` goes to the shell —
`Tab`, `Esc`, the function keys, `⌃C`; `⌘C`/`⌘V` copy and paste. When you go
back to the files, the server folder is read again. After `exit`, `Return`
connects again. OriCmd remembers whether you hid the terminal and opens the next
connection the same way.

### Mouse

Right-click (or `Ctrl`-click) opens the context menu: open, open with, view,
show in Finder, clipboard, rename, delete, pack, and the system Services. Files
can be dragged between the panels, from Finder and to Finder; copying by
default, moving with `⌘`. Dropping onto a folder row puts the files into it.

### Command line

Letters typed in a panel go to the command line while the cursor stays in the
panel.

| Key | Action |
|---|---|
| `Enter` | Run the command in the current folder (login shell, no window) |
| `Shift+Enter` | Run in Terminal, the window stays open |
| `cd <path>`, a folder path | Change the folder of the active panel |
| `Ctrl+Enter` / `Ctrl+Shift+Enter` | Insert the name / full path of the file under the cursor |
| `Esc` | Clear the command line |

## Colors

Settings → Colors: the theme — as in the system, light or dark (for OriCmd only,
switches at once); the color of marked files, the cursor and the cursor text,
alternating row backgrounds; the panel preview shows the result right away.
File Colors… colors names by mask (archives, pictures, scripts — examples
included); in the dark theme these colors are shown lighter, so they stay readable.

## Your own keys

Settings → Keyboard → Keyboard Shortcuts…: any `cm_*` command can get its own
shortcut (double-click a row and press the keys). The "Import wincmd.ini…"
button takes the assignments from the `[Shortcuts]` section of a `wincmd.ini`
file — they are added to the standard keys.

## Start menu

Your own commands: Start → Change Start Menu…. A command runs in the shell in the
folder of the active panel; the parameters `%P` (folder of the active panel),
`%N` (file under the cursor), `%S` (selected files), `%T` / `%M` (folder and
file under the cursor in the other panel) are inserted already quoted. A command
can have its own shortcut (`CM+E` is ⌃⌘E) and run in Terminal; Customize
Toolbar… puts commands on the button bar.

## Internal associations

Files → Internal Associations… (or the button in Settings): for a mask
(`*.swift;*.json`) you choose programs for `Enter`, `F3` and `F4`. A program is
an application (the Application… button) or a shell command: `%P` is the file's
folder, `%N` its name; without parameters the path is added at the end
(`code -g`, `qlmanage -p`). The first matching entry with a program for that key
wins; otherwise the standard behavior applies. A `*` mask at the end of the list
sets a program for all other files.

## Settings

OriCmd → Settings… (`⌘,`) — a window with panes:

- **General** — interface language, automatic update checks.
- **Panels** — panel preview, font, command line, function key and drive
  buttons, button bar setup.
- **Colors** — light or dark theme (or as in the system), panel preview,
  colors of marked files and the cursor, alternating rows, colors by file mask.
- **Operations** — defaults of the copy dialog (overwrite mode, verification,
  attributes), confirmation of moving to the Trash, internal associations,
  Start menu.
- **Keyboard** — quick search mode, your own shortcuts, a note about the F keys
  on a Mac.

## Interface language

English and Russian. By default the system language is used; Settings → General
chooses the language for OriCmd only (the Restart Now button applies it at once).

## Development

A Debug build can play key scenarios and save window snapshots — see
`OriCmd/App/DebugAutomation.swift`. The scenarios only work on explicitly given
test folders (`ORICMD_LEFT`, `ORICMD_RIGHT`); `scripts/test/` has the test data,
the regression suite and local test servers.

Release: `scripts/release.sh 0.2 [notes.md]` sets the version, builds the disk
image, commits, tags `v0.2`, pushes to GitHub and publishes the release with the
image (needs `gh auth login`).

## License

GPL-3.0 — see [LICENSE](LICENSE). The terminal uses
[SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) (MIT License; its notice
is in About OriCmd).

OriCmd is not affiliated with Ghisler Software GmbH. Total Commander is a
trademark of its owner.
