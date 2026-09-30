#!/bin/zsh
# Plays key scenarios on fresh test data and checks the results on disk.
cd "$(dirname $0)/../.."
L=build/testdata/left; R=build/testdata/right
pass=0; fail=0
check() { if eval "$2"; then pass=$((pass+1)); echo "ok   $1"; else fail=$((fail+1)); echo "FAIL $1"; fi; }
run() { timeout 120 scripts/test/run.sh "reg-$1" "$2" >/dev/null 2>&1; }

scripts/test/mkdata.sh
run copy "home down space space f5 wait enter wait wait"
check "F5 copies folders" "diff -rq $L/alpha $R/alpha >/dev/null && diff -rq $L/beta $R/beta >/dev/null"

scripts/test/mkdata.sh
run move "alt+r wait text:eadme escape f6 wait enter wait wait"
check "F6 moves to other panel" "[ -f $R/readme.txt ] && [ ! -f $L/readme.txt ]"

scripts/test/mkdata.sh
run mkdir "f7 wait text:made/deep enter wait"
check "F7 creates nested folders" "[ -d $L/made/deep ]"

scripts/test/mkdata.sh
run rename "alt+n wait text:otes escape shift+f6 wait text:renamed enter wait"
check "Shift+F6 renames in place" "[ -f $L/renamed.md ] && [ ! -f $L/notes.md ]"

# Esc closes any dialog, in the Russian interface too (NSAlert gives Esc only to its own "Cancel").
nosheet() { echo "[ -f build/shots/reg-$1.png ] && [ ! -f build/shots/reg-$1-sheet.png ] && [ ! -f build/shots/reg-$1-win1.png ]"; }
scripts/test/mkdata.sh; cp $L/readme.txt $R/
UI_LANGUAGE=ru run escf7 "f7 wait escape wait"
check "Esc closes F7" "$(nosheet escf7)"
UI_LANGUAGE=ru run esccopy "home down f5 wait escape wait"
check "Esc closes the copy dialog" "$(nosheet esccopy)"
UI_LANGUAGE=ru run escattr "alt+r wait text:eadme escape cmd+i wait escape wait"
check "Esc closes Change Attributes" "$(nosheet escattr)"
UI_LANGUAGE=ru run escinfo "alt+a wait text:rchive-t enter wait wait cmd+i wait escape wait"
check "Esc closes a message with one button" "$(nosheet escinfo)"
UI_LANGUAGE=ru run escoverwrite "alt+r wait text:eadme escape f5 wait enter wait wait escape wait wait"
check "Esc cancels the overwrite question" "$(nosheet escoverwrite)"
UI_LANGUAGE=ru run escfind "alt+f7 wait wait wait escape wait"
check "Esc closes Find Files" "$(nosheet escfind)"
UI_LANGUAGE=ru run escsync "cmd:cm_SyncDirs wait wait wait escape wait"
check "Esc closes Synchronize Directories" "$(nosheet escsync)"

# Network shares (localhost only): a closed port is reported at once, a server that
# accepts but never answers (nc) shows "Connecting…", and Esc cancels the mount.
run badport "cmd:connectToServer wait cmd+a text:smb://127.0.0.1:99999 enter wait wait"
check "a port out of range is refused, not a crash" "[ -f build/shots/reg-badport-sheet.png ]"
run mountfail "cmd:connectToServer wait cmd+a text:smb://127.0.0.1:9 enter wait wait wait"
check "a share whose server does not answer fails at once" "[ -f build/shots/reg-mountfail-sheet.png ]"
nc -lk 127.0.0.1 4455 > build/nc-smb.out 2>&1 &
ncpid=$!
run mountcancel "cmd:connectToServer wait cmd+a text:smb://127.0.0.1:4455 enter wait wait wait escape wait wait"
kill $ncpid 2>/dev/null
check "Esc cancels a share that is still connecting" "[ -s build/nc-smb.out ] && $(nosheet mountcancel)"
rm -f build/nc-smb.out

# Files copied in Microsoft Remote Desktop are promised: the file URLs next to the
# promise point to placeholders of zeros; pasting must ask for the real contents.
scripts/test/mkdata.sh; rm -rf build/testdata/placeholder
run promisepaste "promise:$PWD/$L/readme.txt wait tab cmd+v wait wait wait"
check "pasting promised files gets their contents, not placeholders" "cmp -s $L/readme.txt $R/readme.txt"
rm -rf build/testdata/placeholder
scripts/test/mkdata.sh
run promisetwice "promise:$PWD/$L/readme.txt wait tab cmd+v wait wait wait home cmd+v wait wait wait"
check "a promise pasted twice: the second paste says so, nothing else is moved" "cmp -s $L/readme.txt $R/readme.txt && grep -q 'did not write them again' build/shots/reg-promisetwice-sheet.txt"
rm -rf build/testdata/placeholder
# Remote Desktop's own way: a zero-filled placeholder written only on a coordinated read.
scripts/test/mkdata.sh
run lazypaste "lazyfile:$PWD/$L/readme.txt wait tab cmd+v wait wait wait"
check "pasting a file another program writes on demand gets its contents" "cmp -s $L/readme.txt $R/readme.txt"
rm -rf build/testdata/placeholder
scripts/test/mkdata.sh
run lazydrop "lazyfile:$PWD/$L/readme.txt wait tab drop:$PWD/build/testdata/placeholder/readme.txt wait wait wait"
check "dropping a file another program writes on demand gets its contents" "cmp -s $L/readme.txt $R/readme.txt"
rm -rf build/testdata/placeholder

# An archive inside an archive: Ctrl+PgDn (or Enter) opens it, [..] goes back to the outer
# one onto it, and it cannot be changed (its file is a temporary copy).
nested() { scripts/test/mkdata.sh; (cd $L && mkdir -p nest && echo inner > nest/inside-inner.txt && /usr/bin/zip -q -r inner.zip nest && /usr/bin/zip -q outer.zip inner.zip && rm -rf nest inner.zip); }
nested
run nestpgdn "alt+o wait text:uter enter wait wait alt+i wait text:nner escape ctrl+pagedown wait wait wait home down f5 wait enter wait wait"
check "Ctrl+PgDn opens an archive inside an archive" "[ -f $R/nest/inside-inner.txt ]"
nested
run nestup "alt+o wait text:uter enter wait wait alt+i wait text:nner enter wait wait wait home enter wait wait f5 wait enter wait wait"
check "[..] in a nested archive goes back to the outer one" "[ -f $R/inner.zip ]"
nested
run nestro "alt+o wait text:uter enter wait wait alt+i wait text:nner enter wait wait wait f7 wait"
check "an archive inside an archive is read-only" "[ -f build/shots/reg-nestro-sheet.png ] && ! /usr/bin/unzip -l $L/outer.zip | grep -q 'New'"
nested
run nestdrop "alt+o wait text:uter enter wait wait alt+i wait text:nner enter wait wait wait drop:$PWD/$L/readme.txt wait wait"
check "a drop into an archive inside an archive is refused" "grep -q 'inside an archive is read-only' build/shots/reg-nestdrop-sheet.txt && ! /usr/bin/unzip -l $L/outer.zip | grep -q 'readme'"

# The path bar: a click makes it editable, Enter goes there, Tab completes names.
scripts/test/mkdata.sh
run pathgo "pathclick wait cmd+a text:$PWD/$L/alpha enter wait f7 wait text:made enter wait"
check "the path bar goes to a typed folder" "[ -d $L/alpha/made ]"
scripts/test/mkdata.sh
run pathtab "pathclick wait cmd+a text:$PWD/$L/alp tab wait enter wait f7 wait text:made2 enter wait"
check "Tab in the path bar completes a folder name" "[ -d $L/alpha/made2 ]"
scripts/test/mkdata.sh
run pathcycle "pathclick wait cmd+a text:$PWD/$L/fi tab wait tab wait enter wait f5 wait enter wait wait"
check "Tab again in the path bar takes the first of several names" "[ -f $R/file2.txt ]"
scripts/test/mkdata.sh
run pathfile "pathclick wait cmd+a text:$PWD/$L/notes.md enter wait f5 wait enter wait wait"
check "a file typed into the path bar is selected in its folder" "[ -f $R/notes.md ]"

scripts/test/mkdata.sh
run renamef2 "alt+n wait text:otes escape f2 wait text:by-f2 enter wait"
check "F2 renames in place (the extension kept)" "[ -f $L/by-f2.md ] && [ ! -f $L/notes.md ]"

scripts/test/mkdata.sh
run renamef2ext "alt+n wait text:otes escape f2 wait f2 text:txt enter wait"
check "F2 again selects the extension" "[ -f $L/notes.txt ] && [ ! -f $L/notes.md ]"

scripts/test/mkdata.sh
run delete "alt+s wait text:cript escape shift+f8 wait enter wait wait"
check "Shift+F8 deletes permanently" "[ ! -f $L/script.sh ]"

scripts/test/mkdata.sh
run deleteshift "alt+s wait text:cript escape shift+backspace wait enter wait wait"
check "Shift+Delete (⌫) deletes permanently" "[ ! -f $L/script.sh ]"
scripts/test/mkdata.sh
run deletetyping "alt+s wait text:cript escape text:ab shift+backspace wait"
check "Shift+Delete while typing a command deletes a character, not files" "[ -f $L/script.sh ] && [ ! -f build/shots/reg-deletetyping-sheet.png ]"
scripts/test/mkdata.sh; rm -f build/shots/reg-deletemenu-menu.txt
run deletemenu "alt+s wait text:cript escape menu"
check "the context menu has Delete Permanently under Shift" "grep -qx 'Delete Permanently' build/shots/reg-deletemenu-menu.txt"
check "the context menu has Get Info (the Finder's window; not opened here)" "tail -1 build/shots/reg-deletemenu-menu.txt | grep -qx 'Get Info'"

scripts/test/mkdata.sh
run cmdline "text:touch space text:cmd-made.txt enter wait wait"
check "command line runs commands" "[ -f $L/cmd-made.txt ]"

scripts/test/mkdata.sh
run unzip "alt+a wait text:rchive-t enter wait home down space space f5 wait enter wait wait"
check "F5 unpacks from zip" "diff -rq $L/alpha $R/alpha >/dev/null && diff -rq $L/beta $R/beta >/dev/null"

scripts/test/mkdata.sh
run pack "home down alt+f5 wait enter wait wait"
check "Alt+F5 packs" "bsdtar -tf $R/alpha.zip 2>/dev/null | grep -q inside.txt"

scripts/test/mkdata.sh
run packupper "home down alt+f5 wait text:ALPHA forwarddelete forwarddelete forwarddelete forwarddelete text:.ZIP enter wait wait"
check "Alt+F5 to .ZIP makes a zip" "file $R/ALPHA.ZIP | grep -q 'Zip archive'"

scripts/test/mkdata.sh; (cd $L && /usr/bin/zip -q -r app.jar alpha)
run jaredit "alt+a wait text:pp.j escape enter wait wait f7 wait text:newdir enter wait wait wait"
check "Editing a .jar keeps it a zip" "file $L/app.jar | grep -q 'Zip archive' && bsdtar -tf $L/app.jar | grep -q '^newdir/'"

scripts/test/mkdata.sh; (cd $L && /usr/bin/zip -q -r pack.zip alpha); mkdir -p $R/alpha; echo KEEP > $R/alpha/inside.txt
run unpackask "alt+p wait text:ack.z escape alt+f9 wait enter wait escape wait wait"
check "Alt+F9 asks before replacing existing files" "[ \"\$(cat $R/alpha/inside.txt)\" = KEEP ]"

scripts/test/mkdata.sh
run crc "alt+n wait text:otes escape cmd:cm_CRCcreate wait enter wait wait"
check "checksum file verifies with shasum" "(cd $L && shasum -a 256 -c notes.md.sha256 >/dev/null 2>&1)"

scripts/test/mkdata.sh
run mrt "plus wait cmd+a text:*.txt enter wait ctrl+m wait wait text:doc_[C] enter wait wait wait"
check "Multi-Rename renames" "[ -f $L/doc_4.txt ] && [ ! -f $L/readme.txt ]"

# F5 dialog options
scripts/test/mkdata.sh
run filter "home down space space f5 wait tab text:*.txt enter wait wait"
check "F5 only files of this type" "[ -f $R/alpha/inside.txt ] && [ ! -e $R/beta ]"

scripts/test/mkdata.sh
run mask "alt+n wait text:otes escape f5 wait text:$PWD/$R/*.bak enter wait wait"
check "F5 renames by target mask" "cmp -s $L/notes.md $R/notes.bak"

scripts/test/mkdata.sh; echo old > $R/notes.md
defaults write ru.themmag.OriCmd.tests CopyOverwriteMode -int 5
run autorename "alt+n wait text:otes escape f5 wait enter wait wait"
check "F5 overwrite mode: auto-rename copied" "[ \"\$(cat $R/notes.md)\" = old ] && cmp -s $L/notes.md '$R/notes(2).md'"

scripts/test/mkdata.sh; echo old > $R/notes.md; touch -t 203001010000 $R/notes.md
defaults write ru.themmag.OriCmd.tests CopyOverwriteMode -int 4
run older "alt+n wait text:otes escape f5 wait enter wait wait"
check "F5 overwrite mode: only older targets" "[ \"\$(cat $R/notes.md)\" = old ]"

scripts/test/mkdata.sh; mkdir $R/d1 $R/d2
run allfolders "tab home down space space tab alt+n wait text:otes escape f5 wait click:Options_>> wait click:Copy_to_all_2_selected_folders_in_the_target_panel enter wait wait wait"
check "F5 to all selected target folders" "cmp -s $L/notes.md $R/d1/notes.md && cmp -s $L/notes.md $R/d2/notes.md"

# Data safety: the same file under another path, a file meeting a folder.
scripts/test/mkdata.sh; cp $L/readme.txt build/readme.orig
run casemove "alt+r wait text:eadme escape f6 wait text:$PWD/$L/README.txt enter wait wait"
check "F6 changing only the letter case renames" "ls $L | grep -qx README.txt && cmp -s $L/README.txt build/readme.orig"

scripts/test/mkdata.sh; ln -s left build/testdata/link; cp $L/notes.md build/notes.orig
defaults write ru.themmag.OriCmd.tests CopyOverwriteMode -int 2
run selfcopy "alt+n wait text:otes escape f5 wait text:$PWD/build/testdata/link/ enter wait wait"
check "F5 onto itself through a symlink keeps the file" "cmp -s $L/notes.md build/notes.orig"
rm -f build/testdata/link

scripts/test/mkdata.sh; mkdir -p $R/notes.md; echo keep > $R/notes.md/inside.txt
defaults write ru.themmag.OriCmd.tests CopyOverwriteMode -int 2
run fileoverfolder "alt+n wait text:otes escape f5 wait enter wait wait enter wait wait"
check "Overwrite all never replaces a folder by a file silently" "[ -f $R/notes.md/inside.txt ]"
rm -f build/readme.orig build/notes.orig

scripts/test/mkdata.sh; echo long > "$L/$(python3 -c "print('a'*246 + '.txt')")"
run longname "alt+a wait text:aaaa escape f5 wait enter wait wait"
check "F5 copies a file with a 250-character name" "[ \"\$(ls $R | grep -c aaaa)\" = 1 ]"

scripts/test/mkdata.sh
run foldercase "home down f6 wait text:$PWD/$L/ALPHA enter wait wait"
check "F6 changing only the case of a folder renames it" "ls $L | grep -qx ALPHA && [ -f $L/ALPHA/inside.txt ]"

scripts/test/mkdata.sh; mkdir -p $R/alpha; ln $L/alpha/inside.txt $R/alpha/inside.txt; echo extra > $L/alpha/extra.txt
defaults write ru.themmag.OriCmd.tests CopyOverwriteMode -int 2
run hardlink "home down f5 wait enter wait wait"
check "A hard link to the source inside the target does not stop copying" "[ -f $R/alpha/extra.txt ]"

scripts/test/mkdata.sh; echo locked > $R/notes.md; chflags uchg $R/notes.md
defaults write ru.themmag.OriCmd.tests CopyOverwriteMode -int 2
run locked "alt+n wait text:otes escape f5 wait enter wait wait"
check "A locked file is not replaced without the option" "[ \"\$(cat $R/notes.md)\" = locked ] && ls -lO $R/notes.md | grep -q uchg"
chflags nouchg $R/notes.md

scripts/test/mkdata.sh
run clip "alt+n wait text:otes escape cmd+c tab cmd+v wait wait"
check "Cmd+C / Cmd+V copies" "cmp -s $L/notes.md $R/notes.md"

# Associations; the "*" entry keeps every other file away from real apps.
scripts/test/mkdata.sh
defaults write ru.themmag.OriCmd.tests FileAssociations -data $(python3 -c 'import json; print(json.dumps([
  {"id": "00000000-0000-0000-0000-000000000001", "mask": "*.txt", "open": "cp %N %N.opened", "view": "", "edit": "cp %P%N %P%N.edited"},
  {"id": "00000000-0000-0000-0000-000000000002", "mask": "*.md", "open": "", "view": "sh -c \x27cp \"$0\" \"$0.viewed\"\x27", "edit": ""},
  {"id": "00000000-0000-0000-0000-000000000003", "mask": "*", "open": "true", "view": "", "edit": "true"}]).encode().hex())')
run assoc "alt+r wait text:eadme escape f4 wait enter wait alt+n wait text:otes escape f3 wait wait wait wait"
sleep 2  # the programs run in a login shell, which may still be starting
check "associations for Enter / F3 / F4" "[ -f $L/readme.txt.opened ] && [ -f $L/readme.txt.edited ] && [ -f $L/notes.md.viewed ]"

# F3 shows office documents as Quick Look does; a text file with such an extension
# (a PEM server.key is a Keynote extension) stays text.
scripts/test/mkdata.sh
printf 'Quarterly report\n' > $L/report.txt && textutil -convert docx -output $L/report.docx $L/report.txt && rm $L/report.txt
printf -- '-----BEGIN PRIVATE KEY-----\nMIIEvQIBADANBgkqhkiG9w0BAQEFAASC\n-----END PRIVATE KEY-----\n' > $L/server.key
run f3office "alt+r wait text:eport escape f3 wait wait wait wait"
check "F3 shows an office document as Quick Look does" "[ -f build/shots/reg-f3office-win1.png ] && ! grep -q 'PK' build/shots/reg-f3office-win1.txt"
run f3textkey "alt+s wait text:erver escape f3 wait wait wait wait"
check "F3 shows a text file with an office extension as text" "grep -q 'BEGIN PRIVATE KEY' build/shots/reg-f3textkey-win1.txt"

# Lister encodings: UTF-16 is told by itself (no byte order mark here); S shows DOS
# (866) and is kept for the next file (N); A from hex shows Windows-1251 text; the
# text's context menu lists the encodings, the chosen one checked.
scripts/test/mkdata.sh
text='Привет, мир! Hello, world.'
printf '%s\n' "$text" | iconv -f UTF-8 -t UTF-16LE > $L/enc-u16.txt
printf '%s\n' "$text" | iconv -f UTF-8 -t CP866 > $L/enc-dos.txt
printf '%s\n' "$text" | iconv -f UTF-8 -t CP866 > $L/enc-dos2.txt
run encu16 "alt+e wait text:nc-u16 escape f3 wait wait"
check "Lister tells UTF-16 without a byte order mark" "head -1 build/shots/reg-encu16-win1.txt | grep -q 'UTF-16$' && grep -q 'Привет, мир' build/shots/reg-encu16-win1.txt"
run encdos "alt+e wait text:nc-dos. escape f3 wait wait s wait n wait textmenu"
check "Lister: S shows DOS (866), kept for the next file" "head -1 build/shots/reg-encdos-win1.txt | grep -q 'enc-dos2.txt\] — DOS (866)$' && grep -q 'Привет, мир' build/shots/reg-encdos-win1.txt"
check "Lister: the context menu lists the encodings" "grep -q '^Encoding ▸ Automatically .*✓DOS (866)' build/shots/reg-encdos-menu.txt"
run enchex "alt+c wait text:p1251 escape f3 wait wait 3 wait a wait"
check "Lister: A from hex shows Windows-1251 text" "head -1 build/shots/reg-enchex-win1.txt | grep -q 'Windows-1251$' && grep -q 'Привет, мир' build/shots/reg-enchex-win1.txt"

# Syntax highlighting (highlight.js in the sandboxed OriCmdHighlighter service): code
# is colored, plain text is not, H turns it off, a #! script goes by its program; a
# highlighting that never ends (a Debug-only test language) is killed and the next
# file (N) gets a new service; the service reads system files but not the user's.
scripts/test/mkdata.sh
cp OriCmd/Viewer/SyntaxHighlighter.swift $L/code.swift
cp $L/code.swift $L/spin2.swift
printf '#!/usr/bin/env python3\n# comment\ndef hello(name):\n    return f"Hi {name}" + str(42)\n' > $L/pyscript
printf 'let x = 1\n' > $L/spin.oricmdhang
colors() { sed -n 's/^\[text colors: \([0-9]*\)\]$/\1/p' build/shots/reg-$1-win1.txt; }
run hlcode "alt+c wait text:ode.s escape f3 wait wait wait"
check "Lister highlights program code" "[ \"\$(colors hlcode)\" -ge 5 ]"
run hlplain "alt+c wait text:p1251 escape f3 wait wait wait"
check "Lister leaves plain text plain" "[ \"\$(colors hlplain)\" = 1 ]"
run hloff "alt+c wait text:ode.s escape f3 wait wait wait h wait"
check "Lister: H turns highlighting off" "[ \"\$(colors hloff)\" = 1 ]"
run hlshebang "alt+p wait text:yscr escape f3 wait wait wait"
check "Lister highlights a #! script by its program" "[ \"\$(colors hlshebang)\" -ge 3 ]"
printf 'section .text\n_start:\n    mov eax, 4  ; write\n    int 0x80\n' > $L/boot.asm
printf '// arm64\n_main:\n    adrp x0, msg@PAGE\n    mov  x16, #4\n    svc  #0x80\n' > $L/arm.s
run hlasm "alt+b wait text:oot.a escape f3 wait wait wait"
run hlarm "alt+a wait text:rm.s escape f3 wait wait wait"
check "Lister highlights assembly (x86 .asm, ARM .s)" "[ \"\$(colors hlasm)\" -ge 4 ] && [ \"\$(colors hlarm)\" -ge 4 ]"
# A real .xlsx (a zip) shows as Quick Look does; an Excel 2003 XML file named .xlsx
# is text, colored as XML (not as highlight.js's "xlsx", Excel formulae).
python3 -c 'import zipfile, sys; z = zipfile.ZipFile(sys.argv[1], "w", zipfile.ZIP_DEFLATED); z.writestr("[Content_Types].xml", "<Types/>"); z.writestr("xl/workbook.xml", "<workbook/>"); z.close()' $L/book.xlsx
printf '<?xml version="1.0"?>\n<Workbook xmlns="urn:schemas-microsoft-com:office:spreadsheet"><Worksheet><Table><Row><Cell><Data>1</Data></Cell></Row></Table></Worksheet></Workbook>\n' > $L/xmlbook.xlsx
run hlxlsx "alt+b wait text:ook.x escape f3 wait wait wait"
run hlxmlxlsx "alt+x wait text:mlbook escape f3 wait wait wait"
check "a real .xlsx previews, an XML one named .xlsx is colored as XML" "[ \"\$(wc -l < build/shots/reg-hlxlsx-win1.txt | tr -d ' ')\" = 0 ] && grep -q '<Workbook' build/shots/reg-hlxmlxlsx-win1.txt && [ \"\$(colors hlxmlxlsx)\" -ge 4 ]"
run hlhang "alt+s wait text:pin. escape f3 wait wait n wait wait wait wait wait wait wait wait wait wait wait wait wait wait wait wait"
check "a highlighting that never ends is killed, the next file is highlighted" "head -1 build/shots/reg-hlhang-win1.txt | grep -q 'spin2.swift\\]' && [ \"\$(colors hlhang)\" -ge 5 ]"
# The service locks itself down: no file (the user's or the system's), no other
# service (the pasteboard, LaunchServices); a probe colors one character if it got
# through, two if it was refused.
probe() { echo "$2" > $L/probe.$1; run probe-$1-$3 "alt+p wait text:robe.$1 escape f3 wait wait wait wait"; }
probe oricmdfiles "$PWD/$L/readme.txt" user
probe oricmdfiles /System/Library/CoreServices/SystemVersion.plist system
probe oricmdlookup com.apple.pasteboard.1 pasteboard
probe oricmdlookup com.apple.coreservices.launchservicesd launchservices
check "the highlighting service reads no files, not even system ones" "[ \"\$(colors probe-oricmdfiles-user)\" = 3 ] && [ \"\$(colors probe-oricmdfiles-system)\" = 3 ]"
check "the highlighting service reaches neither the pasteboard nor LaunchServices" "[ \"\$(colors probe-oricmdlookup-pasteboard)\" = 3 ] && [ \"\$(colors probe-oricmdlookup-launchservices)\" = 3 ]"
# Its connection to the preferences daemon (opened while starting) writes nothing:
# a service taken over must not change what other programs, OriCmd too, will run.
defaults delete ru.themmag.OriCmd.probe 2>/dev/null
probe oricmdprefs ru.themmag.OriCmd.probe prefs
check "the highlighting service cannot write preferences" "[ \"\$(colors probe-oricmdprefs-prefs)\" = 3 ] && ! defaults read ru.themmag.OriCmd.probe >/dev/null 2>&1"
defaults delete ru.themmag.OriCmd.probe 2>/dev/null
# A reply with overlapping ranges (which could keep the main thread coloring for
# minutes) is refused whole; a service that died and was started again is still
# killed when it hangs (the next text asks its new process identifier).
printf 'abcdef\n' > $L/probe.oricmdoverlap
run hloverlap "alt+p wait text:robe.oricmdo escape f3 wait wait wait wait"
check "Lister refuses a highlighting reply whose ranges overlap" "[ \"\$(colors hloverlap)\" = 1 ]"
printf 'ab\n' > $L/probe.oricmdlongscope
run hllongscope "alt+p wait text:robe.oricmdl escape f3 wait wait wait wait"
check "Lister refuses a highlighting reply with a scope name far too long" "[ \"\$(colors hllongscope)\" = 1 ]"
# A text in no language highlight.js knows (a key) never goes to the service.
printf -- '-----BEGIN PRIVATE KEY-----\nMIIE\n-----END PRIVATE KEY-----\n' > $L/secret.pem
run hlpem "alt+s wait text:ecret escape f3 wait wait wait"
printf -- '-----BEGIN PGP PRIVATE KEY BLOCK-----\nlQOYBF\n-----END PGP PRIVATE KEY BLOCK-----\n' > $L/secret.asc
run hlasc "alt+s wait text:ecret.a escape f3 wait wait wait"
check "a key (PEM, or an armored .asc that highlight.js would take for AsciiDoc) is not sent to the highlighting service" "grep -q '^texts: 0' build/shots/reg-hlpem-highlighter.txt && grep -q 'BEGIN PRIVATE KEY' build/shots/reg-hlpem-win1.txt && grep -q '^texts: 0' build/shots/reg-hlasc-highlighter.txt && grep -q 'PGP PRIVATE KEY' build/shots/reg-hlasc-win1.txt"
printf 'x\n' > $L/r1.oricmdexit
printf 'let x = 1\n' > $L/r2.oricmdhang
run hlrestart "alt+r wait text:1.o escape f3 wait wait wait wait wait wait wait wait wait wait n $(printf 'wait %.0s' {1..40})"
check "a service started again after dying is still killed when it hangs" "grep -q '^kills: 1' build/shots/reg-hlrestart-highlighter.txt"

# Ready-made colors: High contrast's stripes go with another preset, stripes turned on
# in Settings stay. Prints the setting the keys leave.
alternating() {
  defaults write ru.themmag.OriCmd.tests AlternatingRows -bool $1
  timeout 120 open -W -n --env ORICMD_LEFT=$PWD/$L --env ORICMD_RIGHT=$PWD/$R --env "ORICMD_KEYS=$2" --env ORICMD_QUIT=1 \
    build/DerivedData/Build/Products/Debug/OriCmd.app
  defaults read ru.themmag.OriCmd.tests AlternatingRows; defaults delete ru.themmag.OriCmd.tests 2>/dev/null
}
check "Standard colors keep the stripes turned on in Settings" "[ \"\$(alternating true 'colorpreset:3 wait colorpreset:0 wait')\" = 1 ]"
check "another preset takes away High contrast's stripes" "[ \"\$(alternating false 'colorpreset:3 wait colorpreset:1 wait')\" = 0 ]"

# The right button: the context menu at once (default), or marking (Settings → Panels):
# a click marks, a drag marks all it passes (from a marked file: unmarks), held still
# the menu. Rows: 0 [..], 7 cp1251.txt, 8 data.csv, 9 file2.txt, 10 file10.txt.
rightmarks() { defaults write ru.themmag.OriCmd.tests RightMouseButton marks; }
only() { [ "$(ls $R | tr '\n' ' ')" = "$1 " ]; }
scripts/test/mkdata.sh
run rmenu "rightmouse:click:7"
check "right click shows the context menu" "grep -q 'Copy' build/shots/reg-rmenu-menu.txt"
scripts/test/mkdata.sh; rightmarks
run rclick "rightmouse:click:7 rightmouse:click:8 f5 wait enter wait wait"
check "right click marks files (marking mode)" "[ ! -s build/shots/reg-rclick-menu.txt ] && only 'cp1251.txt data.csv'"
scripts/test/mkdata.sh; rightmarks
run rdrag "rightmouse:drag:7-10 f5 wait enter wait wait"
check "a right-button drag marks the files it passes" "only 'cp1251.txt data.csv file10.txt file2.txt'"
scripts/test/mkdata.sh; rightmarks
run runmark "rightmouse:drag:7-10 rightmouse:drag:8-9 f5 wait enter wait wait"
check "a right-button drag from a marked file unmarks" "only 'cp1251.txt file10.txt'"
scripts/test/mkdata.sh; rightmarks
run rhold "rightmouse:hold:7 down f5 wait enter wait wait"
check "the right button held still shows the menu, nothing marked" "grep -q 'Copy' build/shots/reg-rhold-menu.txt && only 'data.csv'"
rightmarks
run rparent "rightmouse:click:0"
check "right click on [..] shows the menu at once (marking mode)" "grep -q . build/shots/reg-rparent-menu.txt"
scripts/test/mkdata.sh; rightmarks
run rctrl "rightmouse:ctrlclick:7 down f5 wait enter wait wait"
check "Control-click shows the menu at once (marking mode), nothing marked" "grep -q 'Copy' build/shots/reg-rctrl-menu.txt && only 'data.csv'"

# Application buttons, with the empty gamma.app (never started); an empty menu file means no menu.
scripts/test/mkdata.sh; rm -f build/shots/reg-app{menu,remove,sheet}-menu.txt
run appmenu "dropapp:$PWD/$L/gamma.app wait rightclickapp:gamma"
check "app button: right click shows its menu" "grep -qx 'Remove from Button Bar' build/shots/reg-appmenu-menu.txt"
run appremove "dropapp:$PWD/$L/gamma.app wait rightclickapp:gamma|Remove_from_Button_Bar wait rightclickapp:gamma"
check "app button: Remove from Button Bar" "[ -f build/shots/reg-appremove-menu.txt ] && [ ! -s build/shots/reg-appremove-menu.txt ]"
run appsheet "dropapp:$PWD/$L/gamma.app wait f7 wait rightclickapp:gamma"
check "app button: no menu under a sheet" "[ -f build/shots/reg-appsheet-menu.txt ] && [ ! -s build/shots/reg-appsheet-menu.txt ]"

scripts/test/servers.sh start
connect() { echo "cmd:connectToServer wait cmd+a text:$1 enter wait $2 wait wait"; }

scripts/test/mkdata.sh
run sftp "$(connect sftp://oritest$PWD/$L) home down down enter wait wait down f5 wait enter wait wait wait"
check "SFTP downloads a folder" "cmp -s $L/beta/deep/deeper/blob.bin $R/deep/deeper/blob.bin"

scripts/test/mkdata.sh; echo upload > $R/up.txt
run ftp "$(connect ftp://tester@127.0.0.1:2121/left 'text:secret enter wait') tab down f5 wait enter wait wait wait"
check "FTP uploads a file" "cmp -s $R/up.txt $L/up.txt"
scripts/test/mkdata.sh; mkdir -p $R/up/sub; echo a > $R/up/a.txt; echo b > $R/up/sub/b.txt; chmod 750 $R/up/sub
run sftpup "$(connect sftp://oritest$PWD/$L) tab home down f5 wait enter wait wait wait"
check "SFTP uploads a folder" "diff -r $R/up $L/up >/dev/null && [ \"\$(stat -f %Lp $L/up/sub)\" = 750 ]"

scripts/test/mkdata.sh
run ftpdown "$(connect ftp://tester@127.0.0.1:2121/left 'text:secret enter wait') home down f5 wait enter wait wait wait"
check "FTP downloads a folder" "diff -r $L/alpha $R/alpha >/dev/null"
scripts/test/mkdata.sh; echo old > $R/notes.md
run sftpskip "$(connect sftp://oritest$PWD/$L) alt+n wait text:otes escape f6 wait enter wait wait click:Skip wait wait"
check "SFTP F6 keeps skipped files on both sides" "[ \"\$(cat $R/notes.md)\" = old ] && [ -f $L/notes.md ]"

scripts/test/mkdata.sh; echo KEEP > $L/readme.md
run sftprename "$(connect sftp://oritest$PWD/$L) alt+n wait text:otes escape shift+f6 wait text:readme enter wait wait"
check "SFTP rename never replaces an existing file" "[ \"\$(cat $L/readme.md)\" = KEEP ] && [ -f $L/notes.md ]"

scripts/test/mkdata.sh; (cd $R && touch "$(printf 'evil\n!date #')")
run sftpnewline "$(connect sftp://oritest$PWD/$L) tab home down f5 wait enter wait wait"
check "SFTP refuses names with line breaks" "! ls $L | grep -q evil"
scripts/test/mkdata.sh; ln -s alpha $L/current; mkdir -p $R/current; echo new > $R/current/new.txt
run sftpsymlinkfolder "$(connect sftp://oritest$PWD/$L) tab alt+c wait text:urrent escape f5 wait enter wait wait wait"
check "SFTP upload into a server symlink to a folder" "[ -f $L/alpha/new.txt ]"

# F6 to the server through a symlinked local path, one file inside kept: nothing local is lost.
scripts/test/mkdata.sh; ln -s right build/testdata/linkright; mkdir -p $R/site $L/site
echo local-index > $R/site/index.html; echo other > $R/site/other.txt; echo server-index > $L/site/index.html
RIGHT_PANEL=$PWD/build/testdata/linkright run sftpmovekept \
  "$(connect sftp://oritest$PWD/$L) tab alt+s wait text:ite escape f6 wait enter wait wait click:Skip wait wait wait"
check "SFTP F6 keeps a folder with a skipped file" "[ \"\$(cat $R/site/index.html)\" = local-index ] && [ \"\$(cat $L/site/index.html)\" = server-index ] && [ -f $L/site/other.txt ]"
rm -f build/testdata/linkright

# The server terminal under the panel: the test sshd's shell (this Mac's) in the test folder.
scripts/test/mkdata.sh
run termtype "$(connect sftp://oritest$PWD/$L) wait ru+ctrl+\` text:touch space text:made-in-terminal.txt enter wait wait"
check "terminal: Ctrl+\` (any layout) types into the shell in the panel's folder" "[ -f $L/made-in-terminal.txt ]"
run termkeys "$(connect sftp://oritest$PWD/$L) wait ctrl+\` f7 wait"
check "terminal: F-keys go to the shell, not to commands" "[ -f build/shots/reg-termkeys.png ] && [ ! -f build/shots/reg-termkeys-sheet.png ]"
run termcd "$(connect sftp://oritest$PWD/$L) home down enter wait wait ctrl+alt+\` ctrl+\` text:touch space text:cd-made.txt enter wait wait"
check "terminal: Ctrl+Option+\` goes to the panel's folder" "[ -f $L/alpha/cd-made.txt ]"
run termexit "$(connect sftp://oritest$PWD/$L) wait ctrl+\` text:exit enter wait wait enter wait wait wait text:touch space text:again.txt enter wait wait"
check "terminal: Return after exit connects again" "[ -f $L/again.txt ]"
rm -f build/shots/reg-termnewtab-terminal.txt
run termnewtab "$(connect sftp://oritest$PWD/$L) wait cmd+t wait wait"
check "terminal: Cmd+T on a server tab opens a local tab" "[ -f build/shots/reg-termnewtab.png ] && [ ! -f build/shots/reg-termnewtab-terminal.txt ]"
run termclosew "$(connect sftp://oritest$PWD/$L) wait cmd+t wait ctrl+shift+tab wait wait ctrl+\` cmd+w wait wait f7 wait"
check "terminal: Cmd+W from the terminal leaves the files focused" "[ -f build/shots/reg-termclosew-sheet.png ]"
run termclosebusy "$(connect sftp://oritest$PWD/$L) wait ctrl+\` text:sleep space text:30 enter wait cmd+t wait ctrl+shift+tab wait cmd+w wait wait"
check "terminal: closing a tab asks while a program runs" "[ -f build/shots/reg-termclosebusy-sheet.png ]"
scripts/test/mkdata.sh
run termshared "$(connect sftp://oritest$PWD/$L) wait ctrl+\` text:sleep space text:4; space text:touch space text:still.txt enter ctrl+\` tab $(connect sftp://oritest$PWD/$L) wait cmd:cm_FtpDisconnect wait wait wait wait wait wait"
check "terminal: Disconnect keeps a connection another panel uses" "[ -f $L/still.txt ] && [ ! -f build/shots/reg-termshared-sheet.png ]"
run termarchive "$(connect sftp://oritest$PWD/$L) wait drive:$PWD/$L wait wait alt+a wait text:rchive-t enter wait wait ctrl+shift+tab wait wait alt+r wait text:eadme escape f5 wait enter wait wait wait"
check "terminal: a server tab after an archive tab downloads with F5" "[ -f $R/readme.txt ]"
run termiso "$(connect sftp://oritest$PWD/$L) wait ru+ctrl+§ text:touch space text:via-iso-key.txt enter wait wait"
check "terminal: Ctrl+§ (ё on Russian – PC) works too" "[ -f $L/via-iso-key.txt ]"
run termtabs "$(connect sftp://oritest$PWD/$L) wait ctrl+\` text:sleep space text:3; space text:touch space text:late.txt enter ctrl+\` drive:/ wait wait wait wait wait wait wait"
check "terminal: a drive button opens a new tab, the shell keeps running" "[ -f $L/late.txt ]"
run termbusy "$(connect sftp://oritest$PWD/$L) wait ctrl+\` text:sleep space text:30 enter wait ctrl+\` cmd:cm_FtpDisconnect wait wait wait"
check "terminal: Disconnect asks while a program runs" "[ -f build/shots/reg-termbusy-sheet.png ]"
run termidle "$(connect sftp://oritest$PWD/$L) wait ctrl+\` wait ctrl+\` cmd:cm_FtpDisconnect wait wait wait"
check "terminal: Disconnect does not ask at the prompt" "[ -f build/shots/reg-termidle.png ] && [ ! -f build/shots/reg-termidle-sheet.png ]"
run termcdbusy "$(connect sftp://oritest$PWD/$L) wait ctrl+\` text:sleep space text:30 enter wait ctrl+\` ctrl+alt+\` wait wait wait"
check "terminal: Ctrl+Option+\` waits for the running program" "[ -f build/shots/reg-termcdbusy-sheet.png ]"
scripts/test/mkdata.sh
run pathserver "$(connect sftp://oritest$PWD/$L) wait pathclick wait cmd+a text:sftp://oritest$PWD/$L/alp tab wait wait enter wait wait f7 wait text:srvmade enter wait wait"
check "the path bar completes and goes to server folders" "[ -d $L/alpha/srvmade ]"

# ⌘K lists the servers connected to: ↓ in the address field picks the latest, Return connects.
scripts/test/mkdata.sh
run recentserver "$(connect sftp://oritest$PWD/$L) wait cmd:cm_FtpDisconnect wait wait cmd:connectToServer wait cmd+a text:x down enter wait wait wait"
check "Connect to Server lists recent servers" "grep -q 'left %' build/shots/reg-recentserver-terminal.txt"
scripts/test/servers.sh stop

echo "passed: $pass, failed: $fail"
[ $fail -eq 0 ]
