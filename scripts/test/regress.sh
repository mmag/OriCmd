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
# A real .xlsx (a zip) shows as Quick Look does; other XML named .xlsx (not Excel
# 2003 XML, which is a table) is text, colored as XML (not as highlight.js's "xlsx",
# Excel formulae).
python3 -c 'import zipfile, sys; z = zipfile.ZipFile(sys.argv[1], "w", zipfile.ZIP_DEFLATED); z.writestr("[Content_Types].xml", "<Types/>"); z.writestr("xl/workbook.xml", "<workbook/>"); z.close()' $L/book.xlsx
printf '<?xml version="1.0"?>\n<export><Workbook name="data"><row id="1">value</row></Workbook></export>\n' > $L/xmlbook.xlsx
run hlxlsx "alt+b wait text:ook.x escape f3 wait wait wait"
run hlxmlxlsx "alt+x wait text:mlbook escape f3 wait wait wait"
check "a real .xlsx previews, an XML one named .xlsx is colored as XML" "[ \"\$(wc -l < build/shots/reg-hlxlsx-win1.txt | tr -d ' ')\" = 0 ] && grep -q '<Workbook' build/shots/reg-hlxmlxlsx-win1.txt && [ \"\$(colors hlxmlxlsx)\" -ge 4 ]"

# Tables (read in the locked helper, shown as a grid): Excel 2003 XML whatever its
# name (two sheets, merged cells, a date), CSV in Windows-1251 with ; and quotes, an
# HTML page named .xls; 1 shows the text, 7 the table again; an external entity reads
# nothing and entity expansion is refused.
cat > $L/report.xlsx <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<?mso-application progid="Excel.Sheet"?>
<Workbook xmlns="urn:schemas-microsoft-com:office:spreadsheet" xmlns:ss="urn:schemas-microsoft-com:office:spreadsheet">
 <Worksheet ss:Name="Sales"><Table>
  <Row><Cell ss:MergeAcross="2"><Data ss:Type="String">Sales report</Data></Cell></Row>
  <Row ss:Index="3"><Cell ss:Index="2"><Data ss:Type="Number">12</Data></Cell><Cell><Data ss:Type="DateTime">2026-09-30T00:00:00.000</Data><Comment><Data>not a value</Data></Comment></Cell></Row>
 </Table></Worksheet>
 <Worksheet ss:Name="Totals"><Table><Row><Cell><Data ss:Type="String">Total</Data></Cell></Row></Table></Worksheet>
</Workbook>
XML
printf 'Имя;Сумма;Комментарий\n"Иванов, И.";100,50;"есть ""кавычки"""\n' | iconv -f UTF-8 -t CP1251 > $L/pay.csv
printf '<html><head><meta charset="windows-1251"></head><body><table><tr><th colspan=2>Выписка</th></tr><tr><td>Остаток</td><td>1&nbsp;000</td></tr></table></body></html>\n' | iconv -f UTF-8 -t CP1251 > $L/bank.xls
printf '<?xml version="1.0"?>\n<!DOCTYPE Workbook [<!ENTITY xxe SYSTEM "file:///etc/hosts">]>\n<Workbook xmlns="urn:schemas-microsoft-com:office:spreadsheet"><Worksheet><Table><Row><Cell><Data>before&xxe;after</Data></Cell></Row></Table></Worksheet></Workbook>\n' > $L/xxe.xlsx
run tbreport "alt+r wait text:eport.x escape f3 wait wait wait wait"
check "Lister shows Excel 2003 XML as a table (merged cells, skipped cells, a date, no comment)" "grep -qx 'Sales report' build/shots/reg-tbreport-win1.txt && grep -qx '2026-09-30' build/shots/reg-tbreport-win1.txt && grep -qx '12' build/shots/reg-tbreport-win1.txt && ! grep -q 'not a value' build/shots/reg-tbreport-win1.txt"
run tbcsv "alt+p wait text:ay.c escape f3 wait wait wait wait"
check "Lister shows a CSV in Windows-1251 with ; and quotes as a table" "head -1 build/shots/reg-tbcsv-win1.txt | grep -q 'Windows-1251$' && grep -qx 'Иванов, И.' build/shots/reg-tbcsv-win1.txt && grep -qx 'есть \"кавычки\"' build/shots/reg-tbcsv-win1.txt"
run tbhtml "alt+b wait text:ank.x escape f3 wait wait wait wait"
check "Lister shows an HTML page named .xls as a table" "grep -qx 'Выписка' build/shots/reg-tbhtml-win1.txt && grep -qx 'Остаток' build/shots/reg-tbhtml-win1.txt"
run tbkeys "alt+r wait text:eport.x escape f3 wait wait wait 1 wait wait 7 wait wait wait"
check "Lister: 1 shows a table's text, 7 the table again" "grep -qx 'Sales report' build/shots/reg-tbkeys-win1.txt && ! grep -q '<Workbook' build/shots/reg-tbkeys-win1.txt"
run tbxxe "alt+x wait text:xe.x escape f3 wait wait wait wait"
check "a table's external entity reads nothing" "! grep -qi 'localhost' build/shots/reg-tbxxe-win1.txt"

# Books (read in the locked helper, pictures sent as pixels): FB2 in Windows-1251
# with a cover, an epigraph, verses and notes; the same zipped; EPUB chapters in
# spine order with a picture; a zip bomb (an entry claiming gigabytes) is refused.
python3 - "$L" <<'PY'
import base64, sys, zipfile, zlib, struct
L = sys.argv[1]
def png(w, h):
    rows = b''.join(b'\x00' + bytes((200, 60, 60)) * w for _ in range(h))
    chunk = lambda t, d: struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(rows)) + chunk(b'IEND', b'')
cover = base64.b64encode(png(60, 90)).decode()
fb2 = f'''<?xml version="1.0" encoding="windows-1251"?>
<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0" xmlns:l="http://www.w3.org/1999/xlink">
<description><title-info><author><first-name>Лев</first-name><last-name>Толстой</last-name></author><book-title>Война и мир</book-title><coverpage><image l:href="#c.png"/></coverpage></title-info></description>
<body><section><title><p>Глава первая</p></title><epigraph><p>Эпиграф</p><text-author>Автор</text-author></epigraph>
<p>Текст с <emphasis>курсивом</emphasis><a l:href="#n1" type="note">1</a>.</p><poem><stanza><v>Строка стиха</v></stanza></poem></section></body>
<body name="notes"><section id="n1"><title><p>1</p></title><p>Текст сноски.</p></section></body><binary id="c.png" content-type="image/png">{cover}</binary></FictionBook>'''
open(L + '/war.fb2', 'wb').write(fb2.encode('cp1251'))
with zipfile.ZipFile(L + '/war.fb2.zip', 'w', zipfile.ZIP_DEFLATED) as z: z.writestr('war.fb2', fb2.encode('cp1251'))
with zipfile.ZipFile(L + '/master.epub', 'w', zipfile.ZIP_DEFLATED) as z:
    z.writestr('mimetype', 'application/epub+zip', compress_type=zipfile.ZIP_STORED)
    z.writestr('META-INF/container.xml', '<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OPS/book.opf"/></rootfiles></container>')
    z.writestr('OPS/book.opf', '<package xmlns="http://www.idpf.org/2007/opf"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>Мастер и Маргарита</dc:title><dc:creator>Булгаков</dc:creator></metadata><manifest><item id="a" href="a.xhtml" media-type="application/xhtml+xml"/><item id="b" href="text/b.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="b"/><itemref idref="a"/></spine></package>')
    z.writestr('OPS/a.xhtml', '<html><head><script src="x.js"/></head><body><h1>Вторая по порядку</h1><p>Конец.</p></body></html>')
    z.writestr('OPS/text/b.xhtml', '<html><head><script>x</script></head><body><h1>Первая по порядку</h1><p>Никогда не <i>разговаривайте</i>.</p><img src="../img/p.png"/></body></html>')
    z.writestr('OPS/img/p.png', png(40, 30))
# A zip whose entry claims 4 GB unpacked.
with zipfile.ZipFile(L + '/bomb.epub', 'w', zipfile.ZIP_DEFLATED) as z:
    z.writestr('META-INF/container.xml', '<container><rootfiles><rootfile full-path="x.opf"/></rootfiles></container>')
data = bytearray(open(L + '/bomb.epub', 'rb').read())
at = data.find(b'PK\x01\x02')
data[at + 24:at + 28] = struct.pack('<I', 0xFFFFFFF0)
open(L + '/bomb.epub', 'wb').write(bytes(data))
PY
run bkfb2 "alt+w wait text:ar.fb2 escape f3 wait wait wait wait textmenu"
check "Lister shows an FB2 book (Windows-1251): title, author, chapter, notes, cover, contents (without the notes' numbers)" "grep -qx 'Contents ▸ Глава первая' build/shots/reg-bkfb2-menu.txt && head -1 build/shots/reg-bkfb2-win1.txt | grep -q 'Лев Толстой · Война и мир$' && grep -q 'Глава первая' build/shots/reg-bkfb2-win1.txt && grep -q 'Текст сноски.' build/shots/reg-bkfb2-win1.txt && grep -q \"\$(printf '\\357\\277\\274')\" build/shots/reg-bkfb2-win1.txt"
run bkfb2zip "alt+w wait text:ar.fb2.z escape f3 wait wait wait wait"
check "Lister shows a zipped FB2 book" "grep -q 'Строка стиха' build/shots/reg-bkfb2zip-win1.txt"
run bkepub "alt+m wait text:aster.e escape f3 wait wait wait wait"
check "Lister shows an EPUB's chapters in spine order, without scripts (<script/> too)" "grep -q 'Конец.' build/shots/reg-bkepub-win1.txt && head -1 build/shots/reg-bkepub-win1.txt | grep -q 'Мастер и Маргарита$' && [ \"\$(grep -n 'по порядку' build/shots/reg-bkepub-win1.txt | head -1 | grep -c Первая)\" = 1 ] && ! grep -qx 'x' build/shots/reg-bkepub-win1.txt"
run bkbomb "alt+b wait text:omb.e escape f3 wait wait wait wait"
check "an EPUB zip bomb is refused (shown as hex, not read)" "! head -1 build/shots/reg-bkbomb-win1.txt | grep -q '·' && grep -q '^00000000' build/shots/reg-bkbomb-win1.txt"
# Crafted files the helper must get through quickly, neither crashing nor filling
# the memory: numbers past any sheet in Excel 2003 XML, cells spanning a thousand
# columns and many rows, entity expansion ("billion laughs"), and a picture claiming
# 20000 × 20000 pixels in a book (refused before it is decoded).
python3 - "$L" <<'PY'
import sys, zlib, struct, base64
L = sys.argv[1]
big = 9223372036854775807
open(L + '/overflow.xml', 'w').write('<?xml version="1.0"?><Workbook xmlns="urn:schemas-microsoft-com:office:spreadsheet" xmlns:ss="urn:schemas-microsoft-com:office:spreadsheet"><Worksheet><Table>'
    f'<Row ss:Index="{big}"/><Row/><Row><Cell ss:Index="-{big}" ss:MergeAcross="{big}" ss:MergeDown="{big}"><Data>survived</Data></Cell></Row></Table></Worksheet></Workbook>')
open(L + '/spans.xls', 'w').write('<table><tr>' + '<td rowspan=60000 colspan=1000>x</td>' * 20 + '</tr>' + '<tr><td>y</td></tr>' * 20000 + '</table>')
laughs = '<!ENTITY a0 "lol">' + ''.join('<!ENTITY a%d "%s">' % (i, ('&a%d;' % (i - 1)) * 10) for i in range(1, 10))
open(L + '/laughs.xml', 'w').write(f'<?xml version="1.0"?><!DOCTYPE Workbook [{laughs}]><Workbook xmlns="urn:schemas-microsoft-com:office:spreadsheet"><Worksheet><Table><Row><Cell><Data>&a9;</Data></Cell></Row></Table></Worksheet></Workbook>')
w = h = 20000
raw = zlib.compress(b''.join(b'\x00' + b'\x00' * ((w + 7) // 8) for _ in range(h)), 9)
chunk = lambda t, d: struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 1, 0, 0, 0, 0)) + chunk(b'IDAT', raw) + chunk(b'IEND', b'')
open(L + '/huge.fb2', 'w').write('<?xml version="1.0"?><FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0" xmlns:l="http://www.w3.org/1999/xlink"><body><section><p>Текст рядом с огромной картинкой.</p><image l:href="#p"/></section></body>'
    f'<binary id="p" content-type="image/png">{base64.b64encode(png).decode()}</binary></FictionBook>')
PY
run crafted "alt+o wait text:verflow escape f3 wait wait wait wait escape alt+s wait text:pans escape f3 wait wait wait wait wait wait escape alt+l wait text:aughs escape f3 wait wait wait wait escape alt+h wait text:uge escape f3 wait wait wait wait wait"
check "crafted tables and books neither crash nor hang the helper; a huge picture is refused" "grep -q 'Текст рядом с огромной картинкой.' build/shots/reg-crafted-win1.txt && ! grep -q \"\$(printf '\\357\\277\\274')\" build/shots/reg-crafted-win1.txt && grep -q '^kills: 0' build/shots/reg-crafted-highlighter.txt && ! ls ~/Library/Logs/DiagnosticReports | grep -q '^OriCmdHighlighter'"
# Mobipocket and Kindle: MOBI 6 (PalmDOC) and AZW3 (KF8) made by calibre from the EPUB
# above (scripts/test/samples), a HUFF/CDIC-compressed MOBI (one phrase compressed in
# turn), and a book protected by DRM, which is said so.
cp scripts/test/samples/book.mobi $L/master.mobi
cp scripts/test/samples/book.azw3 $L/master.azw3
python3 - "$L" <<'PY'
import struct, sys
L = sys.argv[1]
def palmdb(records):
    table, offset = b'', 78 + len(records) * 8 + 2
    for r in records:
        table += struct.pack('>I', offset) + b'\0' * 4
        offset += len(r)
    return b'huff'.ljust(32, b'\0') + b'\0' * 28 + b'BOOKMOBI' + struct.pack('>IIH', 0, 0, len(records)) + table + b'\0\0' + b''.join(records)
text = 'Привет, <b>мир</b>! \x01 конец.'.encode()
mobi = bytearray(0xE8)
mobi[0:4] = b'MOBI'
for offset, value in ((4, 0xE8), (0x1C - 16, 65001), (0x24 - 16, 6), (0x6C - 16, 0xFFFFFFFF), (0x70 - 16, 2), (0x74 - 16, 2)):
    struct.pack_into('>I', mobi, offset, value)
record0 = struct.pack('>HHIHHHH', 17480, 0, len(text), 1, 4096, 0, 0) + bytes(mobi)
huff = b'HUFF' + struct.pack('>III', 0x18, 24, 24 + 1024) + b'\0' * 8 + struct.pack('>I', (255 << 8) | 0x88) * 256 + b'\0' * 256
entries = [struct.pack('>H', 2) + bytes([190, 189]) if j == 1 else struct.pack('>H', 0x8001) + bytes([j]) for j in range(256)]
offsets, position = b'', 512
for entry in entries:
    offsets += struct.pack('>H', position)
    position += len(entry)
cdic = b'CDIC' + struct.pack('>III', 0x10, 256, 8) + offsets + b''.join(entries)
open(L + '/huff.mobi', 'wb').write(palmdb([record0, bytes(255 - b for b in text), huff, cdic]))
data = bytearray(open(L + '/master.mobi', 'rb').read())
struct.pack_into('>H', data, struct.unpack_from('>I', data, 78)[0] + 12, 2)
open(L + '/drm.mobi', 'wb').write(bytes(data))
PY
run bkmobi "alt+m wait text:aster.m escape f3 wait wait wait wait"
run bkazw3 "alt+m wait text:aster.a escape f3 wait wait wait wait"
check "Lister shows MOBI 6 and AZW3 books (title, author, chapters, a picture)" "head -1 build/shots/reg-bkmobi-win1.txt | grep -q 'Булгаков · Мастер и Маргарита$' && grep -q 'Никогда не разговаривайте.' build/shots/reg-bkmobi-win1.txt && grep -q \"\$(printf '\\357\\277\\274')\" build/shots/reg-bkmobi-win1.txt && grep -q 'Вторая по порядку' build/shots/reg-bkazw3-win1.txt && grep -q \"\$(printf '\\357\\277\\274')\" build/shots/reg-bkazw3-win1.txt"
run bkhuff "alt+h wait text:uff escape f3 wait wait wait wait"
check "Lister reads a HUFF/CDIC-compressed MOBI" "grep -q 'Привет, мир! AB конец.' build/shots/reg-bkhuff-win1.txt"
run bkdrm "alt+d wait text:rm.m escape f3 wait wait wait wait"
check "a MOBI protected by DRM is said so, its text not shown" "grep -q 'protected (DRM)' build/shots/reg-bkdrm-win1.txt && ! grep -q 'разговаривайте' build/shots/reg-bkdrm-win1.txt"
# DjVu (samples made with DjVuLibre): the text layer (BZZ) page after page, with a
# hint when DjVuLibre is not there; a document without a text layer is said so; a
# damaged text layer neither hangs nor crashes. With DjVuLibre's ddjvu (built into
# build/djvulibre, if it is) the pages are drawn by it in a sandbox, F7 shows the text.
cp scripts/test/samples/scan.djvu $L/scan.djvu
cp scripts/test/samples/notext.djvu $L/notext.djvu
python3 - "$L" <<'PY'
import sys
L = sys.argv[1]
data = bytearray(open(L + '/scan.djvu', 'rb').read())
at = data.find(b'TXTz')
for k in range(at + 12, min(at + 60, len(data)), 3):
    data[k] ^= 0xA5
open(L + '/broken.djvu', 'wb').write(bytes(data))
PY
run djtext "alt+s wait text:can.d escape f3 wait wait wait wait"
check "Lister shows a DjVu text layer page after page (a hint without DjVuLibre)" "grep -q 'Привет, мир! Первая страница.' build/shots/reg-djtext-win1.txt && grep -q 'Текст второй страницы.' build/shots/reg-djtext-win1.txt && grep -q 'install DjVuLibre' build/shots/reg-djtext-win1.txt"
run djnotext "alt+n wait text:otext.d escape f3 wait wait wait wait"
run djbroken "alt+b wait text:roken.d escape f3 wait wait wait wait"
check "a DjVu without a text layer is said so; a damaged one does not hang" "grep -q 'no text layer' build/shots/reg-djnotext-win1.txt && [ -f build/shots/reg-djbroken-win1.txt ]"
if [ -x build/djvulibre/bin/ddjvu ]; then
  ORICMD_DDJVU=$PWD/build/djvulibre/bin/ddjvu run djpages "alt+s wait text:can.d escape f3 wait wait wait wait wait"
  ORICMD_DDJVU=$PWD/build/djvulibre/bin/ddjvu run djfind "alt+s wait text:can.d escape f3 wait wait wait wait f7 wait wait wait"
  check "DjVu pages are drawn by ddjvu (sandboxed); F7 shows the text layer" "head -1 build/shots/reg-djpages-win1.txt | grep -q '— 2 pages$' && grep -qx '1 / 2' build/shots/reg-djpages-win1.txt && grep -q 'Привет, мир!' build/shots/reg-djfind-win1.txt"
else
  echo "skip DjVu pages: no build/djvulibre/bin/ddjvu"
fi
# Crafted books (security review): a CDIC whose thousands of entries all name one
# 32 KB phrase (copies would take gigabytes), picture numbers far out of range (the
# arithmetic would trap), a DjVu page with 64 text layers of 16 MB each once
# decompressed (only the last counts, within a budget): each opens at once, the
# helper neither crashes nor is killed.
python3 - "$L" <<'PY'
import struct, sys
L = sys.argv[1]
def palmdb(records):
    table, offset = b'', 78 + len(records) * 8 + 2
    for r in records:
        table += struct.pack('>I', offset) + b'\0' * 4
        offset += len(r)
    return b'bomb'.ljust(32, b'\0') + b'\0' * 28 + b'BOOKMOBI' + struct.pack('>IIH', 0, 0, len(records)) + table + b'\0\0' + b''.join(records)
def header(compression, length, huffman=0xFFFFFFFF, count=0, first_image=0xFFFFFFFF):
    mobi = bytearray(0xE8)
    mobi[0:4] = b'MOBI'
    for offset, value in ((4, 0xE8), (0x1C - 16, 65001), (0x24 - 16, 6), (0x6C - 16, first_image),
                          (0x70 - 16, huffman), (0x74 - 16, count)):
        struct.pack_into('>I', mobi, offset, value)
    return struct.pack('>HHIHHHH', compression, 0, length, 1, 4096, 0, 0) + bytes(mobi)
# 16000 entries, all pointing at one phrase of 32000 bytes of "A".
huff = b'HUFF' + struct.pack('>III', 0x18, 24, 24 + 1024) + b'\0' * 8 + struct.pack('>I', (255 << 8) | 0x88) * 256 + b'\0' * 256
entries = 16000
phrase_at = entries * 2
cdic = b'CDIC' + struct.pack('>III', 0x10, entries, 14) + struct.pack('>H', phrase_at) * entries \
    + struct.pack('>H', 0x8000 | 32000) + b'A' * 32000
text = bytes([255, 254])
open(L + '/phrases.mobi', 'wb').write(palmdb([header(17480, 2, 2, 2), text, huff, cdic]))
body = ('<p>Картинки вне всяких номеров.</p><img recindex="-9223372036854775808"><img recindex="9223372036854775807">'
        '<img src="kindle:embed:7VVVVVVVVVVVV"><img recindex="00000">').encode()
open(L + '/numbers.mobi', 'wb').write(palmdb([header(1, len(body), first_image=2), body, b'not a picture']))
PY
if [ -x build/djvulibre/bin/bzz ]; then
  python3 -c "import sys; sys.stdout.buffer.write(bytes([0,0,0]) + b'a\x1f' * (8 * 1024 * 1024 - 2))" > build/testdata/layer.txt
  printf '\x00\x00\x0bБомба.' > build/testdata/last.txt
  build/djvulibre/bin/bzz -e build/testdata/layer.txt build/testdata/layer.bzz
  build/djvulibre/bin/bzz -e build/testdata/last.txt build/testdata/last.bzz
  python3 - "$L" <<'PY'
import struct, sys
L = sys.argv[1]
def chunk(tag, body):
    return tag + struct.pack('>I', len(body)) + body + (b'\0' if len(body) % 2 else b'')
big, last = open('build/testdata/layer.bzz', 'rb').read(), open('build/testdata/last.bzz', 'rb').read()
page = b'DJVU' + chunk(b'INFO', struct.pack('>HHBBHBB', 100, 100, 24, 0, 300, 22, 1)) \
    + b''.join(chunk(b'TXTz', big) for _ in range(63)) + chunk(b'TXTz', last)
open(L + '/layers.djvu', 'wb').write(b'AT&T' + chunk(b'FORM', page))
PY
  # 300 pages, each with a text layer that expands past BZZ's 16 MB and fails.
  python3 -c "import sys; sys.stdout.buffer.write(bytes([0,0,0]) + b'x' * (17 * 1024 * 1024))" > build/testdata/huge.txt
  build/djvulibre/bin/bzz -e4096 build/testdata/huge.txt build/testdata/huge.bzz
  python3 - "$L" <<'PY'
import struct, sys
L = sys.argv[1]
def chunk(tag, body):
    return tag + struct.pack('>I', len(body)) + body + (b'\0' if len(body) % 2 else b'')
big = open('build/testdata/huge.bzz', 'rb').read()
page = chunk(b'FORM', b'DJVU' + chunk(b'INFO', struct.pack('>HHBBHBB', 100, 100, 24, 0, 300, 22, 1)) + chunk(b'TXTz', big))
open(L + '/manypages.djvu', 'wb').write(b'AT&T' + chunk(b'FORM', b'DJVM' + chunk(b'DIRM', bytes([0x81, 0x01, 0x2c])) + page * 300))
PY
fi
run bkphrases "alt+p wait text:hrases escape f3 wait wait wait"
run bknumbers "alt+n wait text:umbers.m escape f3 wait wait wait"
check "a CDIC naming one phrase thousands of times, and picture numbers out of range, are read" "grep -q 'AAAAAAAA' build/shots/reg-bkphrases-win1.txt && grep -q 'Картинки вне всяких номеров.' build/shots/reg-bknumbers-win1.txt && grep -q '^kills: 0' build/shots/reg-bknumbers-highlighter.txt && ! ls ~/Library/Logs/DiagnosticReports | grep -q '^OriCmdHighlighter'"
if [ -f $L/layers.djvu ]; then
  run djlayers "alt+l wait text:ayers escape f3 wait wait wait"
  check "a DjVu page with 64 huge text layers shows its last one at once" "grep -q 'Бомба.' build/shots/reg-djlayers-win1.txt && grep -q '^kills: 0' build/shots/reg-djlayers-highlighter.txt"
  run djmany "alt+m wait text:anypages escape f3 wait wait wait wait"
  check "300 pages of text layers that fail to expand are given up at once" "grep -q 'no text layer' build/shots/reg-djmany-win1.txt && grep -q '^kills: 0' build/shots/reg-djmany-highlighter.txt"
fi

# ddjvu gets the document on its standard input: a DjVu from an archive (a temporary
# copy under /private/var) is drawn too. A ddjvu that pours out more than a picture,
# or ignores being asked to stop, is killed; the text layer is shown instead.
if [ -x build/djvulibre/bin/ddjvu ]; then
  (cd $L && zip -q djvu.zip scan.djvu)
  ORICMD_DDJVU=$PWD/build/djvulibre/bin/ddjvu run djarchive "alt+d wait text:jvu.z enter wait wait alt+s wait text:can escape f3 wait wait wait wait wait"
  check "a DjVu from an archive is drawn by ddjvu" "grep -q 'pages drawn: [1-9]' build/shots/reg-djarchive-win1.txt"
fi
mkdir -p build/fakeddjvu/flood/bin build/fakeddjvu/stubborn/bin
printf '#include <unistd.h>\n#include <string.h>\nint main(void) { static char b[1 << 20]; memset(b, 7, sizeof b); for (;;) if (write(1, b, sizeof b) < 0) return 1; }\n' | clang -x c -o build/fakeddjvu/flood/bin/ddjvu -
printf '#include <signal.h>\n#include <unistd.h>\nint main(void) { signal(SIGTERM, SIG_IGN); for (;;) pause(); }\n' | clang -x c -o build/fakeddjvu/stubborn/bin/ddjvu -
ORICMD_DDJVU=$PWD/build/fakeddjvu/flood/bin/ddjvu run djflood "alt+s wait text:can.d escape f3 wait wait wait wait wait"
check "a ddjvu pouring out data is cut off; the text layer is shown" "grep -q 'Привет, мир!' build/shots/reg-djflood-win1.txt && ! pgrep -f build/fakeddjvu/flood >/dev/null"
ORICMD_DDJVU=$PWD/build/fakeddjvu/stubborn/bin/ddjvu run djstubborn "alt+s wait text:can.d escape f3 $(printf 'wait %.0s' {1..34})"
check "a ddjvu ignoring SIGTERM is killed after the time limit; the text layer is shown" "grep -q 'Привет, мир!' build/shots/reg-djstubborn-win1.txt && ! pgrep -f build/fakeddjvu/stubborn >/dev/null"
pkill -KILL -f "$PWD/build/fakeddjvu/" 2>/dev/null
# STL models in 3D (read in the helper): binary (with a header starting "solid", as
# many have), text (numbers with exponents), triangles with corners that are not
# numbers left out; a file that is neither shows as hex; 1 shows the text of a text STL.
python3 - "$L" <<'PY'
import math, struct, sys, os
L = sys.argv[1]
def binary(name, triangles, header=b'solid binary part'):
    with open(L + '/' + name, 'wb') as f:
        f.write(header.ljust(80, b' ') + struct.pack('<I', len(triangles)))
        for t in triangles:
            f.write(struct.pack('<3f', 0, 0, 0) + b''.join(struct.pack('<3f', *v) for v in t) + b'\0\0')
ring = []
for i in range(64):
    for j in range(32):
        p = lambda i, j: ((30 + 10 * math.cos(2 * math.pi * j / 32)) * math.cos(2 * math.pi * i / 64),
                          (30 + 10 * math.cos(2 * math.pi * j / 32)) * math.sin(2 * math.pi * i / 64),
                          10 + 10 * math.sin(2 * math.pi * j / 32))
        ring += [(p(i, j), p(i + 1, j), p(i + 1, j + 1)), (p(i, j), p(i + 1, j + 1), p(i, j + 1))]
binary('ring.stl', ring)
nan = float('nan')
binary('holes.stl', [((0, 0, 0), (1, 0, 0), (0, 1, 0)), ((nan, 0, 0), (1, 0, 0), (0, 1, 0)), ((0, 0, 0), (1, 0, 0), (0, 0, 2))])
with open(L + '/box.stl', 'w') as f:
    f.write('solid box\n')
    for t in [((0, 0, 0), (10, 0, 0), (10, 10, 5)), ((0, 0, 0), (10, 10, 5), (0, 10, 5))]:
        f.write('facet normal 0 0 0\nouter loop\n' + ''.join('vertex %.3E %g %g\n' % v for v in t) + 'endloop\nendfacet\n')
    f.write('endsolid box\n')
open(L + '/noise.stl', 'wb').write(os.urandom(5000))
big = 3.0e38
binary('huge.stl', [((-big, -big, 0), (big, -big, 0), (big, big, 0)), ((-big, -big, 0), (big, big, 0), (-big, big, big))])
PY
run stlring "alt+r wait text:ing.s escape f3 wait wait wait"
check "Lister shows a binary STL in 3D (its size and triangles in the title)" "grep -q '\[model: 4096 triangles\]' build/shots/reg-stlring-win1.txt && head -1 build/shots/reg-stlring-win1.txt | grep -q '80 × 80 × 20, triangles: 4.*096'"
run stlbox "alt+b wait text:ox.s escape f3 wait wait wait"
run stlholes "alt+h wait text:oles.s escape f3 wait wait wait"
check "Lister shows a text STL, and leaves out triangles that are not numbers" "grep -q '\[model: 2 triangles\]' build/shots/reg-stlbox-win1.txt && grep -q '\[model: 2 triangles\]' build/shots/reg-stlholes-win1.txt"
run stlhuge "alt+h wait text:uge.s escape f3 wait wait wait"
check "an STL with corners near Float's limits is shown, its size in scientific notation" "grep -q '\[model: 2 triangles\]' build/shots/reg-stlhuge-win1.txt && head -1 build/shots/reg-stlhuge-win1.txt | grep -q '6E38 × 6E38 × 3E38'"
run stlnoise "alt+n wait text:oise.s escape f3 wait wait wait"
run stltext "alt+b wait text:ox.s escape f3 wait wait wait 1 wait"
check "a file named .stl that is no model shows as hex; 1 shows a text STL's text" "! grep -q '\[model' build/shots/reg-stlnoise-win1.txt && grep -q '00000000' build/shots/reg-stlnoise-win1.txt && grep -q 'vertex 1.000E+01' build/shots/reg-stltext-win1.txt"

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
# A text that makes the service take memory without end: it ends itself near 2 GB
# (not killed by OriCmd's time limit), the text stays plain, the next file is colored.
echo "anything" > $L/mem1.oricmdmemory
printf 'func greet() -> String { "Привет" }\nlet x = 1\n' > $L/mem2.swift
run hlmemory "alt+m wait text:em1 escape f3 $(printf 'wait %.0s' {1..10}) n $(printf 'wait %.0s' {1..20})"
check "a service taking memory without end ends itself; the next file is colored" "head -1 build/shots/reg-hlmemory-win1.txt | grep -q 'mem2.swift' && [ \"\$(colors hlmemory)\" -ge 5 ] && grep -q '^kills: 0' build/shots/reg-hlmemory-highlighter.txt"

# Ready-made colors: High contrast's stripes go with another preset, stripes turned on
# in Settings stay. Prints the setting the keys leave.
alternating() {
  defaults write ru.themmag.OriCmd.tests AlternatingRows -bool $1
  timeout 120 open -g -W -n --env ORICMD_LEFT=$PWD/$L --env ORICMD_RIGHT=$PWD/$R --env "ORICMD_KEYS=$2" --env ORICMD_QUIT=1 \
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

# Ctrl+Shift+Left/Right (Ctrl+arrows switch spaces in macOS): the other panel shows the
# folder of a file (the file selected), a folder's contents, an archive's contents; in an
# archive, the same archive folder.
panels() { cat build/shots/reg-$1-panels.txt 2>/dev/null; }
scripts/test/mkdata.sh
run xfile "alt+r wait text:eadme escape ctrl+shift+right wait wait"
check "Ctrl+Shift+Right on a file: its folder, the file selected" "panels xfile | grep -q '^right: .*/left | cursor: readme.txt'"
run xfolder "alt+a wait text:lpha escape ctrl+shift+right wait wait"
check "Ctrl+Shift+Right on a folder: its contents" "panels xfolder | grep -q '^right: .*/left/alpha |'"
run xarchive "alt+a wait text:rchive-t escape ctrl+shift+right wait wait wait"
check "Ctrl+Shift+Right on an archive: its contents" "panels xarchive | grep -q '^right: .*/left/archive-test.zip |'"
run xinarchive "alt+a wait text:rchive-t enter wait wait alt+b wait text:eta escape ctrl+shift+right wait wait wait"
check "Ctrl+Shift+Right in an archive: the same archive folder" "panels xinarchive | grep -q '^right: .*/archive-test.zip/beta |'"
mkdir -p $R/sub
run xleft "tab alt+s wait text:ub escape ctrl+shift+left wait wait"
check "Ctrl+Shift+Left from the right panel" "panels xleft | grep -q '^left: .*/right/sub |'"

# Drive buttons: the Finder's volume menu; a disk image (in build/testdata) is renamed
# (its mount point stays: it is not in /Volumes) and ejected from it, the panel on it
# leaving first.
run drivehome "wait drivemenu:$HOME"
check "drive menu of the home folder: no Eject" "grep -qx 'Open in Other Panel' build/shots/reg-drivehome-menu.txt && ! grep -q Eject build/shots/reg-drivehome-menu.txt"
if hdiutil create -quiet -size 4m -fs HFS+ -volname OriTest build/testdata/ori.dmg \
   && mkdir -p build/testdata/mnt && hdiutil attach -quiet build/testdata/ori.dmg -mountroot $PWD/build/testdata/mnt; then
  M=$PWD/build/testdata/mnt/OriTest
  run drivemenu "wait drivemenu:$M"
  check "drive menu of a disk image: Eject and Rename" "grep -q '^Eject' build/shots/reg-drivemenu-menu.txt && grep -q '^Rename' build/shots/reg-drivemenu-menu.txt"
  run driveother "wait drivemenu:$M|Open_in_Other wait wait"
  check "drive menu: Open in Other Panel" "panels driveother | grep -q '^right: .*/mnt/OriTest |'"
  run driverename "drive:$M wait drivemenu:$M|Rename wait cmd+a text:OriRenamed enter wait wait wait"
  check "drive menu: Rename" "diskutil info $M | grep -q 'Volume Name: *OriRenamed'"
  run driveeject "drive:$M wait drivemenu:$M|Eject wait wait wait wait"
  check "drive menu: Eject, the panel leaves first" "! hdiutil info | grep -q testdata/ori.dmg && ! panels driveeject | grep -q mnt/"
  hdiutil info | grep -q testdata/ori.dmg && hdiutil detach -quiet -force $M
fi

# Tabs dragged: to the other panel (moved there and shown, the cursor kept), the only
# tab of a panel (copied), to another place of the same bar.
scripts/test/mkdata.sh
run tabmove "alt+a wait text:lpha escape cmd+t wait droptab:left:1:right:0 wait wait"
check "a tab dragged to the other panel moves there" "panels tabmove | grep -q '^left: .*tabs: left$' && panels tabmove | grep -q '^right\*: .*/left | cursor: alpha | tabs: left, right$'"
run tabcopy "droptab:left:0:right:1 wait wait"
check "a panel's only tab dragged to the other panel is copied" "panels tabcopy | grep -q '^left: .*tabs: left$' && panels tabcopy | grep -q '^right\*: .*tabs: right, left$'"
run taborder "cmd+t wait alt+a wait text:lpha enter wait droptab:left:1:left:0 wait wait"
check "a tab dragged along its bar changes places" "panels taborder | grep -q '^left\*: .*/left/alpha |.*tabs: alpha, left$'"

# The middle button (the mouse wheel) closes the tab it is clicked on, the current one
# or another.
run tabmiddle "cmd+t wait alt+a wait text:lpha enter wait tabmiddleclick:0 wait wait"
check "a middle click closes another tab" "panels tabmiddle | grep -q '^left\*: .*/left/alpha |.*tabs: alpha$'"
run tabmiddlecurrent "cmd+t wait alt+a wait text:lpha enter wait tabmiddleclick:1 wait wait"
check "a middle click closes the current tab" "panels tabmiddlecurrent | grep -q '^left\*: .*/left |.*tabs: left$'"

# Find Files, Advanced: the date (between, not older than), the size, attributes
# (tri-state), the subfolder levels.
scripts/test/mkdata.sh
mkdir -p $L/found/sub/deeper $L/found/folder.dat
head -c 5000 /dev/zero > $L/found/small.dat; head -c 4000000 /dev/zero > $L/found/big.dat
head -c 2500000 /dev/zero > $L/found/sub/deeper/deep.dat; touch $L/found/.hidden.dat
head -c 100 /dev/zero > $L/found/old.dat; touch -t 202001150000 $L/found/old.dat
printf '#!/bin/sh\n' > $L/found/run.dat; chmod +x $L/found/run.dat; ln -s big.dat $L/found/link.dat
head -c 10 /dev/zero > $L/found/sub/locked.dat; chflags uchg $L/found/sub/locked.dat
findfiles() { run "$1" "alt+f7 wait set:findMask=*.dat set:findIn=$PWD/$L/found $2 click:Start_Search wait wait wait"; }
found() { grep '^\[row\]' build/shots/reg-$1-win1.txt 2>/dev/null | sed 's|.*/found/||' | tr '\n' ' '; }
findfiles fsize "click:Advanced set:findSizeOn=on set:findSizeOp=> set:findSize=2 set:findSizeUnit=MB"
check "Find Files: size > 2 MB (a link to a big file too)" "[ \"\$(found fsize)\" = 'big.dat link.dat sub/deeper/deep.dat ' ]"
findfiles fsizeeq "click:Advanced set:findSizeOn=on set:findSizeOp== set:findSize=2 set:findSizeUnit=MB"
check "Find Files: size = 2 MB takes 2 to 3 MB" "[ \"\$(found fsizeeq)\" = 'sub/deeper/deep.dat ' ]"
findfiles fdate "click:Advanced set:findBetween=on set:findFrom=2020-01-01 set:findTo=2020-02-01"
check "Find Files: date between" "[ \"\$(found fdate)\" = 'old.dat ' ]"
findfiles fage "click:Advanced set:findOlder=on set:findAge=1 set:findAgeUnit=days"
check "Find Files: not older than a day" "found fage | grep -q 'big.dat' && ! found fage | grep -q 'old.dat'"
findfiles fexec "click:Advanced set:findAttr-executable=on"
check "Find Files: executable" "[ \"\$(found fexec)\" = 'run.dat ' ]"
findfiles flocked "click:Advanced set:findAttr-locked=on"
check "Find Files: locked" "[ \"\$(found flocked)\" = 'sub/locked.dat ' ]"
findfiles flink "click:Advanced set:findAttr-symbolicLink=on"
check "Find Files: symbolic link" "[ \"\$(found flink)\" = 'link.dat ' ]"
findfiles fnot "click:Advanced set:findAttr-folder=off set:findAttr-hidden=off"
check "Find Files: neither a folder nor hidden" "[ \"\$(found fnot)\" = 'big.dat link.dat old.dat run.dat small.dat sub/deeper/deep.dat sub/locked.dat ' ]"
findfiles fdepth0 "set:findDepth=None"
check "Find Files: no subfolders" "! found fdepth0 | grep -q sub/"
findfiles fdepth1 "set:findDepth=1"
check "Find Files: one level of subfolders" "found fdepth1 | grep -q 'sub/locked.dat' && ! found fdepth1 | grep -q deeper"
findfiles fbadsize "click:Advanced set:findSizeOn=on set:findSize=lots"
check "Find Files: a wrong number is not searched with" "grep -qx 'Enter a whole number.' build/shots/reg-fbadsize-win1.txt && [ -z \"\$(found fbadsize)\" ]"
chflags nouchg $L/found/sub/locked.dat

# Find Files, text: encodings (one, all of them), case, whole words, regular
# expressions (for the text and for the name), files not containing the text, hex.
scripts/test/mkdata.sh
mkdir -p $L/texts; T=$L/texts
printf 'Привет, мир!\n' > $T/utf8.txt
for e in CP1251:cp1251 KOI8-R:koi8 CP866:dos866; do printf 'Привет, мир!\n' | iconv -f UTF-8 -t ${e%%:*} > $T/${e#*:}.txt; done
{ printf '\xff\xfe'; printf 'Привет, мир!\n' | iconv -f UTF-8 -t UTF-16LE; } > $T/utf16.txt
echo 'the cat sat' > $T/english.txt; echo 'concatenate' > $T/concat.txt; echo 'word42 here' > $T/words.txt
# A zip of known contents (random bytes could hold the words looked for).
printf 'zzzz' > $L/z.txt; (cd $L && zip -q texts/packed.zip z.txt)
textfind() { run "$1" "alt+f7 wait set:findIn=$PWD/$T $2 click:Start_Search wait wait wait"; }
textfound() { grep '^\[row\]' build/shots/reg-$1-win1.txt 2>/dev/null | sed 's|.*/texts/||' | tr '\n' ' '; }
textfind tutf8 "set:findText=привет"
check "Find Files: a text in UTF-8, whatever the case" "[ \"\$(textfound tutf8)\" = 'utf8.txt ' ]"
textfind tall "set:findText=привет set:findEncoding=All_of_them"
check "Find Files: a text in all the encodings" "[ \"\$(textfound tall)\" = 'cp1251.txt dos866.txt koi8.txt utf8.txt utf16.txt ' ]"
textfind t1251 "set:findText=Привет set:findCase=on set:findEncoding=Windows-1251"
check "Find Files: a case-sensitive text in Windows-1251" "[ \"\$(textfound t1251)\" = 'cp1251.txt ' ]"
textfind tsub "set:findText=cat"
check "Find Files: a text inside a word" "[ \"\$(textfound tsub)\" = 'concat.txt english.txt ' ]"
textfind twhole "set:findText=cat set:findWholeWords=on"
check "Find Files: whole words" "[ \"\$(textfound twhole)\" = 'english.txt ' ]"
textfind tregex "set:findText=word[0-9]+_here set:findTextRegex=on"
check "Find Files: a regular expression for the text" "[ \"\$(textfound tregex)\" = 'words.txt ' ]"
textfind tnot "set:findMask=*.txt set:findText=cat set:findNot=on"
check "Find Files: files not containing the text" "[ \"\$(textfound tnot)\" = 'cp1251.txt dos866.txt koi8.txt utf8.txt utf16.txt words.txt ' ]"
textfind tname "set:findMask=^(koi|dos) set:findNameRegex=on"
check "Find Files: a regular expression for the name" "[ \"\$(textfound tname)\" = 'dos866.txt koi8.txt ' ]"
textfind thex "set:findText=50_4B_03_04 set:findEncoding=Hex"
check "Find Files: bytes in hex" "[ \"\$(textfound thex)\" = 'packed.zip ' ]"
textfind tbadregex "set:findText=( set:findTextRegex=on"
check "Find Files: a wrong regular expression is said so" "grep -qx 'The regular expression for the text is not valid.' build/shots/reg-tbadregex-win1.txt"
textfind tbadhex "set:findText=5 set:findEncoding=Hex"
check "Find Files: wrong hex is said so" "grep -qx 'Enter the bytes in hex, as 50 4B 03 04.' build/shots/reg-tbadhex-win1.txt"

# Find Files, duplicates: by contents (the beginning, then the rest), name, size;
# a hard link is the file once, empty files are not compared.
scripts/test/mkdata.sh
D=$L/dups; mkdir -p $D/a $D/b $D/c $D/d
head -c 100000 /dev/urandom > $D/a/photo.jpg; cp $D/a/photo.jpg $D/b/photo.jpg; cp $D/a/photo.jpg $D/c/copy.bin
head -c 100000 /dev/urandom > $D/d/photo.jpg; ln $D/a/photo.jpg $D/hard.jpg; touch $D/e1.txt $D/e2.txt
head -c 150000 /dev/urandom > $D/big1.dat; cp $D/big1.dat $D/big2.dat; printf 'x' >> $D/big1.dat; printf 'y' >> $D/big2.dat
dupfind() { run "$1" "alt+f7 wait set:findIn=$PWD/$D click:Advanced set:findDuplicates=on $2 click:Start_Search wait wait wait"; }
dupfound() { grep '^\[row\]' build/shots/reg-$1-win1.txt 2>/dev/null | sed 's|^\[row\] ||; s|.*/dups/||' | tr '\n' '/'; }
dupfind dupcontents ""
check "Find Files: duplicates by contents" "[ \"\$(dupfound dupcontents)\" = '3 files, 100 KB each/a/photo.jpg/b/photo.jpg/c/copy.bin/' ]"
dupfind dupname "set:findSameName=on set:findSameContents=off"
check "Find Files: duplicates by name" "[ \"\$(dupfound dupname)\" = '3 files/a/photo.jpg/b/photo.jpg/d/photo.jpg/' ]"
dupfind dupsize "set:findSameSize=on set:findSameContents=off"
check "Find Files: duplicates by size" "[ \"\$(dupfound dupsize)\" = '4 files, 100 KB each/a/photo.jpg/b/photo.jpg/c/copy.bin/d/photo.jpg/2 files, 150 KB each/big1.dat/big2.dat/' ]"
dupfind dupboth "set:findSameName=on"
check "Find Files: duplicates by name and contents" "[ \"\$(dupfound dupboth)\" = '2 files, 100 KB each/a/photo.jpg/b/photo.jpg/' ]"
dupfind dupnone "set:findSameContents=off"
check "Find Files: duplicates need something in common" "grep -qx 'Choose what the duplicates have in common.' build/shots/reg-dupnone-win1.txt"

# Find Files in archives: names and text inside zip and tar.gz (a damaged archive
# is passed over); Go to File opens the archive at the entry.
scripts/test/mkdata.sh
A=$L/arch; mkdir -p $A; cp $L/archive-test.zip $L/bundle.tar.gz $A/; echo 'hello from disk' > $A/inside.txt
head -c 3000 /dev/urandom > $A/broken.zip
archfind() { run "$1" "alt+f7 wait set:findIn=$PWD/$A $2 click:Start_Search wait wait wait $3"; }
archfound() { grep '^\[row\]' build/shots/reg-$1-win1.txt 2>/dev/null | sed 's|.*/arch/||' | tr '\n' ' '; }
archfind aname "set:findMask=inside.txt set:findArchives=on"
check "Find Files: names in archives" "[ \"\$(archfound aname)\" = 'archive-test.zip/alpha/inside.txt bundle.tar.gz/alpha/inside.txt inside.txt ' ]"
archfind anoarch "set:findMask=inside.txt"
check "Find Files: archives are not looked into unless asked" "[ \"\$(archfound anoarch)\" = 'inside.txt ' ]"
archfind atext "set:findText=hello_from_alpha set:findArchives=on"
# (The zip keeps so short a text unpacked: the zip itself has it too.)
check "Find Files: a text in archives" "[ \"\$(archfound atext)\" = 'archive-test.zip archive-test.zip/alpha/inside.txt bundle.tar.gz/alpha/inside.txt ' ]"
archfind afolder "set:findMask=deeper set:findArchives=on click:Advanced set:findAttr-folder=on"
check "Find Files: a folder in an archive" "[ \"\$(archfound afolder)\" = 'archive-test.zip/beta/deep/deeper ' ]"
archfind agoto "set:findMask=inside.txt set:findArchives=on" "click:Go_to_File wait wait wait"
check "Find Files: Go to File opens the archive at the entry" "panels agoto | grep -q '^left\*: .*/arch/archive-test.zip/alpha | cursor: inside.txt'"

# Find Files with the Spotlight index: the files come from the index (only those
# named so are looked at), by the subfolder levels too. Skipped without indexing.
if mdutil -s / 2>/dev/null | grep -q 'Indexing enabled'; then
  scripts/test/mkdata.sh
  mkdir -p $L/spot/sub; touch $L/spot/spot-a.txt $L/spot/spot-b.txt $L/spot/sub/spot-c.txt
  for i in {1..20}; do [ "$(mdfind -onlyin $PWD/$L/spot 'kMDItemFSName == "spot-*"' | wc -l)" -ge 3 ] && break; sleep 1; done
  run spotall "alt+f7 wait set:findMask=spot-*.txt set:findIndex=on click:Start_Search wait wait wait"
  check "Find Files: names from the Spotlight index" "[ \"\$(grep '^\[row\]' build/shots/reg-spotall-win1.txt | sed 's|.*/left/||' | tr '\n' ' ')\" = 'spot/spot-a.txt spot/spot-b.txt spot/sub/spot-c.txt ' ] && grep -qx 'Done: 3 found, 3 scanned' build/shots/reg-spotall-win1.txt"
  run spotdepth "alt+f7 wait set:findMask=spot-*.txt set:findIndex=on set:findDepth=1 click:Start_Search wait wait wait"
  check "Find Files: the index by the subfolder levels" "[ \"\$(grep '^\[row\]' build/shots/reg-spotdepth-win1.txt | sed 's|.*/left/||' | tr '\n' ' ')\" = 'spot/spot-a.txt spot/spot-b.txt ' ]"
fi

# Find Files templates: a search saved, the dialog changed, the search loaded back
# (the General tab shown) and run; a template deleted.
scripts/test/mkdata.sh
mkdir -p $L/tpl; head -c 4000000 /dev/zero > $L/tpl/big.dat; head -c 5000 /dev/zero > $L/tpl/small.dat; touch $L/tpl/big.txt
tplsave="alt+f7 wait set:findIn=$PWD/$L/tpl set:findMask=*.dat click:Advanced set:findSizeOn=on set:findSize=2 set:findSizeUnit=MB click:Templates click:Save… wait text:bigfiles enter wait"
run tplload "$tplsave set:findMask=*.txt click:Advanced set:findSizeOn=off click:Templates set:findTemplates=bigfiles click:Load wait click:Start_Search wait wait wait"
check "Find Files: a saved search loaded back" "[ \"\$(grep '^\[row\]' build/shots/reg-tplload-win1.txt | sed 's|.*/tpl/||' | tr '\n' ' ')\" = 'big.dat ' ] && grep -qx '\*.dat' build/shots/reg-tplload-win1.txt"
run tplsaved "$tplsave"
run tpldelete "$tplsave set:findTemplates=bigfiles click:Delete wait"
check "Find Files: a saved search listed, then deleted" "grep -qx '\[row\] bigfiles' build/shots/reg-tplsaved-win1.txt && ! grep -q '^\[row\] bigfiles' build/shots/reg-tpldelete-win1.txt"

# Encrypted zip archives: the password is asked for (again while wrong, nothing
# unpacked meanwhile), F3 inside asks too, so does a change.
scripts/test/mkdata.sh
(cd $L && echo 'the secret text' > secret.txt && zip -q -P secret crypto.zip secret.txt && rm secret.txt)
run encok "alt+c wait text:rypto escape alt+f9 wait enter wait text:secret enter wait wait wait"
check "An encrypted zip is unpacked with its password" "[ \"\$(cat $R/secret.txt 2>/dev/null)\" = 'the secret text' ]"
rm -f $R/secret.txt
run encwrong "alt+c wait text:rypto escape alt+f9 wait enter wait text:wrong enter wait wait"
check "A wrong password is asked for again, nothing unpacked" "grep -qx 'The password is wrong. Enter it again:' build/shots/reg-encwrong-sheet.txt && [ ! -e $R/secret.txt ]"
run encview "alt+c wait text:rypto enter wait wait alt+s wait text:ecret escape f3 wait text:secret enter wait wait wait"
check "F3 in an encrypted zip asks for the password" "grep -q 'the secret text' build/shots/reg-encview-win1.txt"
run encedit "alt+c wait text:rypto enter wait wait alt+s wait text:ecret escape f8 wait enter wait wait"
check "A change of an encrypted zip asks for its password" "grep -qx 'The archive is encrypted. Enter its password:' build/shots/reg-encedit-sheet.txt && unzip -l $L/crypto.zip | grep -q secret.txt"

# Alt+F5 options: the compression (store, best), a password (AES-256, ZipCrypto;
# Pack only with the same password twice), moving into the archive, one archive per
# file; an AES archive read back and changed (it keeps its password and AES).
scripts/test/mkdata.sh
echo 'packed secret' > $L/secret.txt; yes 'compressible line of text' | head -5000 > $L/plain.txt
echo one > $L/sep1.txt; echo two > $L/sep2.txt; echo moving > $L/movable.txt
run pstore "alt+p wait text:lain escape alt+f5 wait set:packCompression=Store_(no_compression) enter wait wait"
check "Alt+F5: a zip without compression" "unzip -v $R/plain.zip | grep plain.txt | grep -q Stored"
run pbest "alt+p wait text:lain escape alt+f5 wait set:packPath=$PWD/$R/plain.tar.gz set:packCompression=Best enter wait wait"
check "Alt+F5: a tar.gz with the best compression" "[ \"\$(xxd -s 8 -l 1 -p $R/plain.tar.gz)\" = 02 ]"
run paes "alt+s wait text:ecret escape alt+f5 wait set:packEncrypt=on set:packPassword=pw set:packRepeat=pw enter wait wait"
check "Alt+F5: a zip encrypted with AES-256" "[ \"\$(xxd -s 8 -l 2 -p $R/secret.zip)\" = 6300 ]"
run pcrypto "alt+s wait text:ecret escape alt+f5 wait set:packPath=$PWD/$R/zc.zip set:packEncrypt=on set:packEncryption=ZipCrypto_(weak,_for_old_programs) set:packPassword=pw set:packRepeat=pw enter wait wait"
check "Alt+F5: a zip encrypted with ZipCrypto (unzip reads it)" "[ \"\$(unzip -P pw -p $R/zc.zip)\" = 'packed secret' ]"
run pdiffer "alt+s wait text:ecret escape alt+f5 wait set:packPath=$PWD/$R/no.zip set:packEncrypt=on set:packPassword=pw set:packRepeat=px enter wait wait"
check "Alt+F5: different passwords pack nothing" "grep -qx 'The passwords differ.' build/shots/reg-pdiffer-sheet.txt && [ ! -e $R/no.zip ] && ! grep -qx 'px' build/shots/reg-pdiffer-sheet.txt"
run pmove "alt+m wait text:ovable escape alt+f5 wait set:packMove=on enter wait wait wait"
check "Alt+F5: moved into the archive" "[ \"\$(unzip -p $R/movable.zip)\" = moving ] && [ ! -e $L/movable.txt ]"
run psep "plus wait cmd+a text:sep*.txt enter wait alt+f5 wait set:packSeparate=on enter wait wait wait"
check "Alt+F5: one archive per file" "[ \"\$(unzip -p $R/sep1.zip)\" = one ] && [ \"\$(unzip -p $R/sep2.zip)\" = two ]"
rm -f $L/secret.txt
run paesread "tab wait alt+s wait text:ecret escape alt+f9 wait enter wait text:pw enter wait wait wait"
check "An AES zip is read back with its password" "[ \"\$(cat $L/secret.txt 2>/dev/null)\" = 'packed secret' ]"
run paesedit "tab wait alt+s wait text:ecret enter wait wait tab wait alt+s wait text:ep1 escape f5 wait enter wait text:pw enter wait wait wait"
check "An encrypted zip is changed with its password, still AES" "unzip -l $R/secret.zip | grep -q sep1.txt && unzip -l $R/secret.zip | grep -q secret.txt && [ \"\$(xxd -s 8 -l 2 -p $R/secret.zip)\" = 6300 ]"

# Alt+Shift+F9 tests archives: intact ones, a damaged one (its file named), an
# encrypted one with its password.
scripts/test/mkdata.sh
mkdir -p $L/tests; cp $L/archive-test.zip $L/tests/good.zip; cp $L/bundle.tar.gz $L/tests/good.tar.gz
python3 -c "d=bytearray(open('$L/archive-test.zip','rb').read()); d[len(d)//2]^=0xFF; open('$L/tests/bad.zip','wb').write(d)"
(cd $L/tests && echo 'the secret text' > s.txt && zip -q -P secret crypto.zip s.txt && rm s.txt)
run tok "alt+t wait text:ests enter wait plus wait cmd+a text:good* enter wait alt+shift+f9 wait wait wait"
check "Alt+Shift+F9: intact archives" "grep -qx '2 archives were read through: their contents are intact.' build/shots/reg-tok-sheet.txt"
run tbad "alt+t wait text:ests enter wait plus wait cmd+a text:*d.zip enter wait alt+shift+f9 wait wait wait"
check "Alt+Shift+F9: a damaged archive and its file" "grep -q '^“bad.zip”: “beta/deep/deeper/blob.bin” is damaged' build/shots/reg-tbad-sheet.txt && grep -qx 'The other archives (1) are intact.' build/shots/reg-tbad-sheet.txt"
run tenc "alt+t wait text:ests enter wait alt+c wait text:rypto escape alt+shift+f9 wait text:secret enter wait wait wait"
check "Alt+Shift+F9: an encrypted archive with its password" "grep -qx '“crypto.zip” was read through: its contents are intact.' build/shots/reg-tenc-sheet.txt"

# Locked tabs: one keeps its folder (going elsewhere opens a new tab), one locked
# with folder changes allowed comes back to its folder; a tab renamed; the tab
# menu shows the lock.
scripts/test/mkdata.sh
run lock "cmd:cm_ToggleLockCurrentTab alt+a wait text:lpha enter wait wait"
check "A locked tab keeps its folder, a new tab opens" "panels lock | grep -q '^left\*: .*/left/alpha | cursor: .. | tabs: \*left, alpha$'"
run lockback "cmd:cm_ToggleLockCurrentTab alt+a wait text:lpha enter wait wait ctrl+shift+tab wait wait"
check "Back in the locked tab, as it was" "panels lockback | grep -q '^left\*: .*/left | cursor: alpha | tabs: \*left, alpha$'"
run dcastay "cmd:cm_ToggleLockDcaCurrentTab alt+a wait text:lpha enter wait wait"
check "A tab locked with changes allowed changes its folder" "panels dcastay | grep -q '^left\*: .*/left/alpha |.*tabs: \*alpha$'"
run dca "cmd:cm_ToggleLockDcaCurrentTab alt+a wait text:lpha enter wait wait cmd+t wait ctrl+shift+tab wait wait"
check "...and comes back to its folder when chosen again" "panels dca | grep -q '^left\*: .*/left |.*tabs: \*left, alpha$'"
run tabrename "cmd+t wait tabmenu:0|Rename_Tab wait text:Work enter wait"
check "A tab renamed" "panels tabrename | grep -q 'tabs: Work, left$'"
run lockmenu "cmd+t wait tabmenu:0|Lock_Tab, wait tabmenu:0"
check "The tab menu shows the lock" "grep -qx '✓Lock Tab, Allow Folder Changes' build/shots/reg-lockmenu-menu.txt && grep -qx 'Lock Tab' build/shots/reg-lockmenu-menu.txt"

# Favorite tabs: both panels' tabs saved under a name (a lock too) and shown
# again; a favorite removed.
scripts/test/mkdata.sh
run favload "cmd+t wait alt+a wait text:lpha enter wait wait cmd:cm_ToggleLockCurrentTab menuitem:Save_Current_Tabs… wait text:proj enter wait cmd:cm_ToggleLockCurrentTab ctrl+shift+tab wait cmd+w wait wait menuitem:proj wait wait wait"
check "Favorite tabs shown again, the lock too" "panels favload | grep -q '^left\*: .*/left/alpha |.*tabs: left, \*alpha$' && panels favload | grep -q '^right: .*tabs: right$'"
run favkeep "cmd+t wait menuitem:Save_Current_Tabs… wait text:proj enter wait wait cmd+w wait wait menuitem:proj wait wait"
check "Favorite tabs bring back a closed tab" "panels favkeep | grep -q 'tabs: left, left$'"
run favremove "cmd+t wait menuitem:Save_Current_Tabs… wait text:proj enter wait wait menuitem:Remove>proj wait cmd+w wait wait menuitem:proj wait wait"
check "Favorite tabs removed" "panels favremove | grep -q '^left\*: .*tabs: left$'"

# Selection: only the selected files shown (until All Files or another folder),
# names with details copied, the selection saved to a file and loaded from one
# (names, or paths of this folder's files) and from the clipboard.
scripts/test/mkdata.sh
items() { grep "^$2 items: " build/shots/reg-$1-panels.txt 2>/dev/null | sed "s/^$2 items: //"; }
testclip() { osascript -l JavaScript -e 'ObjC.import("AppKit"); $.NSPasteboard.pasteboardWithName("ru.themmag.OriCmd.tests").stringForType($.NSPasteboardTypeString).js'; }
run onlysel "alt+r wait text:eadme escape space alt+n wait text:otes escape space cmd:cm_ShowOnlySelected wait"
check "Only the selected files shown" "[ \"\$(items onlysel left)\" = '*notes.md, *readme.txt' ]"
run onlyoff "alt+r wait text:eadme escape space cmd:cm_ShowOnlySelected wait cmd:cm_SrcAllFiles wait"
check "All Files shows them all again" "items onlyoff left | grep -q 'beta'"
run onlyleave "alt+a wait text:lpha escape space cmd:cm_ShowOnlySelected wait alt+a wait text:lpha enter wait backspace wait wait"
check "Another folder shows them all again" "panels onlyleave | grep -q '^left\*: .*/left |' && items onlyleave left | grep -q 'beta'"
run details "alt+r wait text:eadme escape space cmd:cm_CopyDetailsToClip wait"
check "Names copied with size, date and permissions" "testclip | grep -qE \"^readme.txt	\$(stat -f %z $L/readme.txt)	[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]{8}	-rw-r--r--\$\""
printf 'readme.txt\nnotes.md\n%s/data.csv\n/elsewhere/file2.txt\nmissing.txt\n' "$PWD/$L" > $L/sel.txt
run selload "file:$PWD/$L/sel.txt cmd:cm_LoadSelectionFromFile wait"
check "A selection loaded from a file" "[ \"\$(items selload left | tr ',' '\n' | grep -c '\*')\" = 3 ] && items selload left | grep -q '\*data.csv' && ! items selload left | grep -q '\*file2.txt'"
run selsave "alt+r wait text:eadme escape space alt+n wait text:otes escape space file:$PWD/$R/saved.txt cmd:cm_SaveSelectionToFile wait"
check "A selection saved to a file" "[ \"\$(cat $R/saved.txt)\" = \"\$(printf 'notes.md\nreadme.txt')\" ]"
run selclip "alt+r wait text:eadme escape space alt+n wait text:otes escape space cmd:cm_CopyNamesToClip cmd:cm_ClearAll wait cmd:cm_LoadSelectionFromClip wait"
check "A selection loaded from the clipboard" "[ \"\$(items selclip left | tr ',' '\n' | grep -c '\*')\" = 2 ]"

# Pause and the speed limit of a copy (a real copy, not an APFS clone): limited, it
# is still under way after a few seconds; paused at once, hardly anything is copied.
scripts/test/mkdata.sh
head -c 40000000 /dev/urandom > $L/big.bin
defaults write ru.themmag.OriCmd.tests CopyAttributes -bool false
run climit "alt+b wait text:ig escape f5 wait enter set:transferSpeed=5_MB/s wait wait wait wait"
part=$(print -l $R/.oricmd-*.part(N) | head -1)
check "A copy keeps to the speed limit" "[ ! -e $R/big.bin ] && [ -n \"$part\" ] && [ \$(stat -f %z $part) -gt 1000000 ] && [ \$(stat -f %z $part) -lt 36000000 ]"
rm -f $R/.oricmd-*.part(N)
defaults write ru.themmag.OriCmd.tests CopyAttributes -bool false
run cpause "alt+b wait text:ig escape f5 wait enter set:transferSpeed=1_MB/s click:Pause wait wait wait"
check "A paused copy waits" "grep -qx 'Copying (paused)' build/shots/reg-cpause-sheet.txt && grep -qx '\\[button\\] Resume' build/shots/reg-cpause-sheet.txt && [ ! -e $R/big.bin ]"
rm -f $R/.oricmd-*.part(N)

# Column sets: the Default columns, a set used by itself in the folders matching
# its masks (and left there), a set chosen in Show → Columns, a column turned on in
# the header menu, a set made in the Column Sets window.
scripts/test/mkdata.sh
columns() { grep "^$2 columns: " build/shots/reg-$1-panels.txt | sed "s/^$2 columns: //"; }
run cdef "wait"
check "The Default columns" "[ \"\$(columns cdef left)\" = 'ext, size, date, attr' ]"
defaults write ru.themmag.OriCmd.tests ColumnSets -array '{name=Photos;columns=(size,dimensions);folders="*/left/alpha";}'
run cauto "alt+a wait text:lpha enter wait wait"
check "A column set used by itself in its folders" "[ \"\$(columns cauto left)\" = 'size, dimensions' ] && [ \"\$(columns cauto right)\" = 'ext, size, date, attr' ]"
defaults write ru.themmag.OriCmd.tests ColumnSets -array '{name=Photos;columns=(size,dimensions);folders="*/left/alpha";}'
run cautoback "alt+a wait text:lpha enter wait wait backspace wait wait"
check "...and not outside them" "[ \"\$(columns cautoback left)\" = 'ext, size, date, attr' ]"
defaults write ru.themmag.OriCmd.tests ColumnSets -array '{name=Photos;columns=(size,dimensions);folders="";}'
run cchoose "menuitem:Columns>Photos wait"
check "A column set chosen for a panel" "[ \"\$(columns cchoose left)\" = 'size, dimensions' ]"
run cheader "headermenu:Kind wait"
check "A column turned on in the header menu" "[ \"\$(columns cheader left)\" = 'ext, size, date, kind, attr' ] && [ \"\$(columns cheader right)\" = 'ext, size, date, kind, attr' ]"
run cwindow "menuitem:Column_Sets… wait click:+ wait set:columnSetName=Wide set:columnSet-kind=on set:columnSet-attr=off wait escape wait menuitem:Columns>Wide wait"
check "A column set made in the Column Sets window" "[ \"\$(columns cwindow left)\" = 'ext, size, date, kind' ]"

# The separate tree: a folder chosen in it is shown in the active panel (the other
# one too after Tab), and it follows the active panel.
scripts/test/mkdata.sh
run streepick "cmd:cm_ToggleSeparateTree1 wait tree:$PWD/$L/beta wait wait tab wait tree:$PWD/$L/alpha wait wait"
check "The separate tree shows its folder in the active panel" "panels streepick | grep -q '^left: .*/left/beta |' && panels streepick | grep -q '^right\*: .*/left/alpha |'"

# Multi-Rename Tool: a rule saved and loaded back, new names from a file (and
# renamed so), new names edited one by one.
scripts/test/mkdata.sh
printf 'one.txt\ntwo.txt\nthree.txt\n' > $L/names.lst
rows() { grep '^\[row\]' build/shots/reg-$1-win1.txt | tr '\n' ';'; }
run rtpl "plus wait cmd+a text:file*.txt enter wait ctrl+m wait wait set:renameMask=doc-[C] wait set:renameTemplates=Save_the_Rule… wait text:docs enter wait set:renameMask=[N]-x wait set:renameTemplates=docs wait"
check "Multi-Rename: a saved rule loaded back" "[ \"\$(rows rtpl)\" = '[row] file2.txt | doc-1.txt;[row] file10.txt | doc-2.txt;' ]"
run rfile "plus wait cmd+a text:file*.txt enter wait ctrl+m wait wait file:$PWD/$L/names.lst click:Names_from_File… wait"
check "Multi-Rename: names from a file (more lines than files)" "[ \"\$(rows rfile)\" = '[row] file2.txt | one.txt;[row] file10.txt | two.txt;' ] && grep -qx '3 names for 2 files' build/shots/reg-rfile-win1.txt"
run rfiledo "plus wait cmd+a text:file*.txt enter wait ctrl+m wait wait file:$PWD/$L/names.lst click:Names_from_File… wait enter wait wait"
check "Multi-Rename: renamed by the names from a file" "[ -e $L/one.txt ] && [ -e $L/two.txt ] && [ ! -e $L/file2.txt ]"
scripts/test/mkdata.sh
run redit 'plus wait cmd+a text:file*.txt enter wait ctrl+m wait wait click:Edit_Names… wait set:renameNames=first.txt\nsecond.txt click:OK wait'
check "Multi-Rename: names edited one by one" "[ \"\$(rows redit)\" = '[row] file2.txt | first.txt;[row] file10.txt | second.txt;' ]"

# Compare by content, editing: a difference copied right or left, a line changed,
# saved as written (CRLF kept; a side without lines removes them); closing with
# changes asks first and keeps the files.
scripts/test/mkdata.sh
cprep() { printf 'a\nb\nc\n' > $L/c1.txt; printf 'a\nB\nc\n' > $L/c2.txt; printf 'one\r\ntwo\r\n' > $L/w1.txt; printf 'one\r\nTWO\r\nthree\r\n' > $L/w2.txt; }
compare() { echo "plus wait cmd+a text:$1 enter wait cmd:cm_CompareFilesByContent wait wait"; }
cprep; run crt "$(compare 'c?.txt') click:Copy_to_Right_→ wait click:Save wait"
check "Compare: a difference copied to the right and saved" "[ \"\$(cat $L/c2.txt)\" = \"\$(printf 'a\nb\nc')\" ]"
cprep; run clt "$(compare 'c?.txt') click:←_Copy_to_Left wait click:Save wait"
check "Compare: a difference copied to the left and saved" "[ \"\$(cat $L/c1.txt)\" = \"\$(printf 'a\nB\nc')\" ]"
cprep; run ced "$(compare 'c?.txt') click:Edit_Line… wait set:compareLeftLine=X click:OK wait click:Save wait"
check "Compare: a line changed and saved" "[ \"\$(cat $L/c1.txt)\" = \"\$(printf 'a\nX\nc')\" ]"
cprep; run cwin "$(compare 'w?.txt') click:Copy_to_Right_→ wait click:Save wait"
check "Compare: CRLF line breaks kept, lines removed" "cmp -s $L/w2.txt <(printf 'one\r\ntwo\r\n')"
cprep; run cclose "$(compare 'c?.txt') click:Copy_to_Right_→ wait escape wait"
check "Compare: closing with changes asks first" "grep -qx 'Save the changes?' build/shots/reg-cclose-win1-sheet.txt && grep -qx \"\\[button\\] Don't Save\" build/shots/reg-cclose-win1-sheet.txt && [ \"\$(cat $L/c2.txt)\" = \"\$(printf 'a\nB\nc')\" ]"

# Ctrl+Z: a file's Finder comment written, shown again for editing, removed.
scripts/test/mkdata.sh
comment() { xattr -px com.apple.metadata:kMDItemFinderComment $1 2>/dev/null | xxd -r -p | plutil -p - 2>/dev/null | tr -d '"'; }
run cmt "alt+r wait text:eadme escape ctrl+z wait text:my-note enter wait"
check "Ctrl+Z: a Finder comment written" "[ \"\$(comment $L/readme.txt)\" = my-note ]"
run cmtread "alt+r wait text:eadme escape ctrl+z wait"
check "Ctrl+Z: the comment shown for editing" "grep -qx 'my-note' build/shots/reg-cmtread-sheet.txt"
run cmtclear "alt+r wait text:eadme escape ctrl+z wait backspace enter wait"
check "Ctrl+Z: an empty comment removes it" "[ -z \"\$(comment $L/readme.txt)\" ] && ! xattr $L/readme.txt | grep -q FinderComment"

# Ctrl+F7 (Unsorted): the order the folder is read in (as ls -f), folders first;
# Ctrl+F3 sorts by name again.
scripts/test/mkdata.sh
mkdir -p $L/uns/dir; for n in zeta alpha mike bravo; do touch $L/uns/$n.txt; done
run uns "alt+u wait text:ns enter wait cmd:cm_SrcUnsorted wait wait"
check "Unsorted: as the folder is read" "[ \"\$(grep '^left items: ' build/shots/reg-uns-panels.txt | sed 's/^left items: //')\" = \"dir, \$(ls -f $L/uns | grep '\.txt\$' | paste -sd, - | sed 's/,/, /g')\" ]"
run unsback "alt+u wait text:ns enter wait cmd:cm_SrcUnsorted wait wait ctrl+f3 wait"
check "...and sorted by name again" "grep -qx 'left items: dir, alpha.txt, bravo.txt, mike.txt, zeta.txt' build/shots/reg-unsback-panels.txt"

# Show → Horizontal Panels: one above the other, and side by side again.
scripts/test/mkdata.sh
run horiz "cmd:cm_HorizontalPanels wait wait"
check "Horizontal Panels: one above the other" "grep -qx 'arrangement: one above the other' build/shots/reg-horiz-panels.txt"
run horizback "cmd:cm_HorizontalPanels wait cmd:cm_HorizontalPanels wait wait"
check "...and side by side again" "grep -qx 'arrangement: side by side' build/shots/reg-horizback-panels.txt"

# The ignore list: a mask, a name and a full path left out of the panels, shown
# again when it is switched off.
scripts/test/mkdata.sh
run ignore "menuitem:Ignore_List… wait set:ignoreList=*.csv\\nalpha\\n$PWD/$L/beta click:OK wait wait"
check "The ignore list leaves out a mask, a name, a path" "! grep '^left items: ' build/shots/reg-ignore-panels.txt | grep -qE 'data.csv|alpha|beta' && grep -q '^left items: .*many' build/shots/reg-ignore-panels.txt"
run ignoreoff "menuitem:Ignore_List… wait set:ignoreList=*.csv\\nalpha click:OK wait cmd:cm_SwitchIgnoreList wait wait"
check "...and shows them again when switched off" "grep '^left items: ' build/shots/reg-ignoreoff-panels.txt | grep -q 'alpha'"

# Alt+F10: a folder tree in a dialog; Enter goes to the folder chosen, Esc stays.
scripts/test/mkdata.sh
run cdtree "alt+f10 wait wait tree:$PWD/$L/beta/deep wait enter wait wait"
check "Alt+F10: the folder chosen in the tree" "panels cdtree | grep -q '^left\*: .*/left/beta/deep |'"
run cdtreeesc "alt+f10 wait wait tree:$PWD/$L/beta/deep wait escape wait"
check "Alt+F10: Esc stays where the panel was" "panels cdtreeesc | grep -q '^left\*: .*/left |'"

# Files → Create Hard Link: another name of the same file (in the other panel by
# default); not for a folder.
scripts/test/mkdata.sh
run hardlink "alt+r wait text:eadme escape cmd:cm_CreateHardLink wait enter wait wait"
check "A hard link made in the other panel" "[ \"\$(stat -f %i $R/readme.txt 2>/dev/null)\" = \"\$(stat -f %i $L/readme.txt)\" ]"
run hardlinkdir "alt+a wait text:lpha escape cmd:cm_CreateHardLink wait enter wait wait"
check "No hard link to a folder" "[ ! -e $R/alpha ] && [ ! -f build/shots/reg-hardlinkdir-sheet.png ]"

# Split File / Combine Files: pieces name.001… and name.crc (the name, size and
# CRC32 as zlib counts them); put together again, the same file; a damaged piece is
# said so; an existing file is asked about.
scripts/test/mkdata.sh
head -c 2500000 /dev/urandom > $L/big.bin
run split "alt+b wait text:ig.bin escape cmd:cm_FileSpliter wait set:splitSize=1_MB enter wait wait"
check "Split: three pieces and the .crc file" "[ \"\$(stat -f %z $R/big.001 $R/big.002 $R/big.003 | paste -sd' ' -)\" = '1048576 1048576 402848' ] && grep -q \"crc32=\$(python3 -c \"import zlib;print('%08X'%zlib.crc32(open('$L/big.bin','rb').read()))\")\" $R/big.crc && grep -q 'filename=big.bin' $R/big.crc"
run combine "tab wait alt+b wait text:ig.001 escape cmd:cm_FileCombine wait text:$PWD/$R/ enter wait wait"
check "Combine: the pieces make the file again" "cmp -s $R/big.bin $L/big.bin"
run combineask "tab wait alt+b wait text:ig.001 escape cmd:cm_FileCombine wait enter wait wait"
check "Combine: an existing file is asked about" "grep -q 'already exists. Replace?' build/shots/reg-combineask-sheet.txt"
rm -f $R/big.bin; printf 'X' | dd of=$R/big.002 bs=1 seek=1000 conv=notrunc 2>/dev/null
run combinebad "tab wait alt+b wait text:ig.001 escape cmd:cm_FileCombine wait text:$PWD/$R/ enter wait wait"
check "Combine: a damaged piece is said so" "grep -q 'do not make' build/shots/reg-combinebad-sheet.txt && [ ! -e $R/big.bin ]"

# Lister, Shift+F7: a regular expression (F3 finds the next), case, bytes in hex
# (found in the hex dump).
scripts/test/mkdata.sh
printf 'alpha word42 beta\nword7 gamma\n' > $L/find.txt
selected() { grep '^\[selected: ' build/shots/reg-$1-win1.txt | sed 's/^\[selected: //; s/\]$//'; }
run lre "alt+f wait text:ind escape f3 wait wait shift+f7 wait set:listerFind=word[0-9]+ set:listerFindRegex=on enter wait"
check "Lister: a regular expression found" "[ \"\$(selected lre)\" = word42 ]"
run lre2 "alt+f wait text:ind escape f3 wait wait shift+f7 wait set:listerFind=word[0-9]+ set:listerFindRegex=on enter wait f3 wait"
check "Lister: F3 finds the next match" "[ \"\$(selected lre2)\" = word7 ]"
run lplain "alt+f wait text:ind escape f3 wait wait shift+f7 wait set:listerFind=GAMMA enter wait"
check "Lister: a text whatever its case" "[ \"\$(selected lplain)\" = gamma ]"
run lcase "alt+f wait text:ind escape f3 wait wait shift+f7 wait set:listerFind=GAMMA set:listerFindCase=on enter wait"
check "Lister: case sensitive, not found" "[ -z \"\$(selected lcase)\" ]"
run lhex "alt+a wait text:rchive-t escape f3 wait wait 1 wait shift+f7 wait set:listerFind=50_4B_03_04 set:listerFindHex=on enter wait wait"
check "Lister: bytes in hex found in the hex dump" "[ \"\$(selected lhex)\" = '50 4B 03 04' ]"

# Printing (a test run writes what would be printed to -print.txt): the file list,
# with the subfolders' files, a text file (its encoding read), the Lister's text.
scripts/test/mkdata.sh
printf 'alpha word42 beta\n' > $L/find.txt
printed() { cat build/shots/reg-$1-print.txt 2>/dev/null; }
run pdir "cmd:cm_PrintDir wait"
check "Print File List" "printed pdir | grep -qE '^alpha +<DIR>' && ! printed pdir | grep -q 'alpha/inside.txt'"
run pdirsub "cmd:cm_PrintDirSub wait"
check "Print File List with Subfolders" "printed pdirsub | grep -qE '^alpha/inside.txt +17 '"
run pfile "alt+c wait text:p1251 escape cmd:cm_PrintFile wait"
check "Print File: a text in its encoding" "printed pfile | grep -q 'Привет, мир!'"
run plister "alt+f wait text:ind escape f3 wait wait cmd+p wait"
check "Lister: ⌘P prints what is shown" "printed plister | grep -qx 'alpha word42 beta'"

# Ctrl+PgDn never starts a file: it opens it as an archive whatever its name (a zip
# named .bin or .docx, an archive inside an archive named .dat); a file that is none
# stays as it is, without a word.
scripts/test/mkdata.sh
cp $L/archive-test.zip $L/packed.bin; cp $L/archive-test.zip $L/report.docx
printf 'hello world\n' > $L/hello.txt; : > $L/empty.dat
(cd $L && cp archive-test.zip inner.dat && zip -q outer.zip inner.dat && rm inner.dat)
run cpbin "alt+p wait text:acked escape ctrl+pagedown wait wait"
run cpdocx "alt+r wait text:eport escape ctrl+pagedown wait wait"
run cpnested "alt+o wait text:uter escape enter wait wait alt+i wait text:nner escape ctrl+pagedown wait wait wait"
check "Ctrl+PgDn opens any archive as one, whatever its name" "panels cpbin | grep -q '^left\\*: .*/packed.bin |' && panels cpdocx | grep -q '^left\\*: .*/report.docx |' && panels cpnested | grep -q '^left\\*: .*/outer.zip/inner.dat |'"
run cptext "alt+h wait text:ello escape ctrl+pagedown wait wait"
run cpempty "alt+e wait text:mpty escape ctrl+pagedown wait wait"
check "Ctrl+PgDn on a file that is no archive does nothing (no message, nothing started)" "[ ! -f build/shots/reg-cptext-sheet.png ] && [ ! -f build/shots/reg-cpempty-sheet.png ] && panels cptext | grep -q '^left\\*: .*/left | cursor: hello.txt' && panels cpempty | grep -q '^left\\*: .*/left | cursor: empty.dat'"

# TypeScript shares .ts with MPEG transport streams: text is shown as code, a stream
# with Quick Look.
printf 'interface User {\n  name: string;\n}\nexport const greet = (u: User): string => `Hi ${u.name}`;\n' > $L/app.ts
python3 -c "open('$L/clip.ts','wb').write((bytes([0x47,0x40,0x11,0x10])+bytes(184))*50)"
run tstext "alt+a wait text:pp.ts escape f3 wait wait wait"
check "Lister: TypeScript .ts is colored text" "grep -q 'interface User' build/shots/reg-tstext-win1.txt && grep -q 'text colors: [1-9]' build/shots/reg-tstext-win1.txt"
run tsvideo "alt+c wait text:lip.ts escape f3 wait wait wait"
check "Lister: an MPEG transport stream .ts is not text" "[ \"\$(wc -l < build/shots/reg-tsvideo-win1.txt)\" -le 1 ]"

# HTML and Markdown as pages, locked: JavaScript off, nothing from the network (a
# server on localhost logs whatever reaches it: nothing may), only files of the page's
# folder (a symlink out of it is refused); 1 shows the source, colored.
scripts/test/mkdata.sh
mkdir -p $L/site/img && cp $L/picture.png $L/site/img/pic.png
echo "SECRET-OUTSIDE" > $L/outside.txt; echo "INSIDE-TEXT" > $L/site/inside.txt; ln -s ../outside.txt $L/site/link.txt
cat > $L/site/page.html <<'EOF'
<!DOCTYPE html><html><head><meta charset="utf-8"><title>Страница</title>
<link rel="preconnect" href="http://127.0.0.1:8765/preconnect"><link rel="stylesheet" href="http://127.0.0.1:8765/leak.css">
<meta http-equiv="refresh" content="1;url=http://127.0.0.1:8765/refresh">
<style>@import url("http://127.0.0.1:8765/import.css"); body { background: url("http://127.0.0.1:8765/bg.png"); }</style>
<script>document.title = "SCRIPT-RAN";</script></head><body onload="document.title='ONLOAD-RAN'">
<h1>Заголовок страницы</h1><img src="img/pic.png"><img src="http://127.0.0.1:8765/leak.png">
<iframe src="http://127.0.0.1:8765/frame"></iframe><iframe src="inside.txt"></iframe><iframe src="link.txt"></iframe>
<iframe src="../outside.txt"></iframe><video src="http://127.0.0.1:8765/video.mp4" autoplay></video></body></html>
EOF
printf -- '---\ntitle: Проба\n---\n# Заголовок Markdown\n\n| Колонка | Число |\n|:--|--:|\n| один | 1 |\n\n```swift\nlet a = "б"\n```\n\n- [x] сделано\n- [ ] нет\n\n![](img/pic.png) ![](http://127.0.0.1:8765/md.png)\n<script>document.title="MD-SCRIPT"</script>\n' > $L/site/README.md
python3 -u -c "
import http.server
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        print('GET', self.path, flush=True); self.send_response(200); self.end_headers(); self.wfile.write(b'x')
    def log_message(self, *a): pass
http.server.HTTPServer(('127.0.0.1', 8765), H).serve_forever()
" > build/leak.log 2>&1 &
leakpid=$!
sleep 1
page() { cat build/shots/reg-$1-win1-page.txt 2>/dev/null; }
run webhtml "alt+s wait text:ite enter wait alt+p wait text:age escape f3 wait wait wait wait wait wait"
run webmd "alt+s wait text:ite enter wait alt+r wait text:EADME escape f3 wait wait wait wait"
kill $leakpid 2>/dev/null
check "Lister: HTML shows as a page, its scripts do not run" "page webhtml | head -1 | grep -qx 'Страница' && page webhtml | grep -q 'Заголовок страницы'"
check "Lister: a page shows files of its folder, not one a symlink leads out to" "page webhtml | grep -q 'iframe: INSIDE-TEXT' && ! page webhtml | grep -q SECRET-OUTSIDE"
check "Lister: Markdown shows as a page (tables, code, task lists), its scripts do not run" "page webmd | head -1 | grep -qx README && page webmd | grep -q 'Заголовок Markdown' && page webmd | grep -q '☑ сделано' && page webmd | grep -q 'один'"
check "Lister: pages load nothing from the network" "[ -f build/leak.log ] && [ ! -s build/leak.log ]"
rm -f build/leak.log
run websource "alt+s wait text:ite enter wait alt+r wait text:EADME escape f3 wait wait wait 1 wait wait"
check "Lister: 1 shows the Markdown source, colored" "grep -q '^# Заголовок Markdown' build/shots/reg-websource-win1.txt && grep -q 'text colors: [2-9]' build/shots/reg-websource-win1.txt"
python3 -c "
import json
data = json.dumps([{'id': i, 'name': 'item %d' % i, 'tags': ['a', 'b']} for i in range(9000)], indent=2)
open('$L/site/bigcode.md', 'w').write('# Большой блок кода\\n\\n\\x60\\x60\\x60json\\n' + data + '\\n\\x60\\x60\\x60\\n\\nКонец.\\n')
"
run webbigcode "alt+s wait text:ite enter wait alt+b wait text:igcode escape f3 wait wait wait wait wait"
check "Lister: Markdown with a long colored code block still shows as a page" "page webbigcode | grep -q 'Большой блок кода' && page webbigcode | grep -q 'Конец.'"

# F lays out JSON, XML, JavaScript, TypeScript (prettier) and HTML in the helper service.
printf '{"name":"OriCmd","list":[1,{"a":null,"b":[]}],"empty":{}, // note\n"n":-1.5e3}' > $L/data.json
printf '<?xml version="1.0"?><root a="1>"><item id="x">Текст</item><empty/><group><sub>1</sub></group></root>' > $L/data.xml
printf 'function f(a,b){if(a){return b.map(x=>x*2)}return null}' > $L/code.js
printf 'interface U{name:string;age?:number}export function g(u:U):string{return u.name}' > $L/types.ts
run fmtjson "alt+d wait text:ata.j escape f3 wait wait f wait wait"
check "Lister: F formats JSON (comments and key order kept)" "grep -q 'formatted' build/shots/reg-fmtjson-win1.txt && grep -qx '    {' build/shots/reg-fmtjson-win1.txt && grep -qx '  \"empty\": {},' build/shots/reg-fmtjson-win1.txt && grep -qx '  // note' build/shots/reg-fmtjson-win1.txt"
run fmtxml "alt+d wait text:ata.x escape f3 wait wait f wait wait"
check "Lister: F formats XML" "grep -qx '  <item id=\"x\">Текст</item>' build/shots/reg-fmtxml-win1.txt && grep -qx '    <sub>1</sub>' build/shots/reg-fmtxml-win1.txt"
run fmtjs "alt+c wait text:ode.j escape f3 wait wait f wait wait"
check "Lister: F formats JavaScript" "grep -qx '        return b.map(x => x \\* 2)' build/shots/reg-fmtjs-win1.txt"
run fmtts "alt+t wait text:ypes escape f3 wait wait f wait wait"
check "Lister: F formats TypeScript" "grep -qx '    age?: number;' build/shots/reg-fmtts-win1.txt"
run fmthtml "alt+s wait text:ite enter wait alt+p wait text:age escape f3 wait wait wait 1 wait f wait wait"
check "Lister: F formats the HTML source" "grep -q 'formatted' build/shots/reg-fmthtml-win1.txt && grep -qx '  <meta charset=\"utf-8\">' build/shots/reg-fmthtml-win1.txt"
run fmtoff "alt+d wait text:ata.j escape f3 wait wait f wait f wait wait"
check "Lister: F again shows the file as it is" "! grep -q formatted build/shots/reg-fmtoff-win1.txt && grep -q '^{\"name\"' build/shots/reg-fmtoff-win1.txt"

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
# A server tab dragged to the other panel takes its connection and its running
# terminal along: the shell started before finishes its command, the panel shows the
# server, and the terminal answers there (Return after it ends reconnects).
scripts/test/mkdata.sh
run tabserver "$(connect sftp://oritest$PWD/$L) wait ctrl+\` text:sleep space text:3; space text:touch space text:moved.txt enter ctrl+\` cmd+t wait droptab:left:0:right:1 wait wait wait wait wait wait"
check "a server tab dragged to the other panel keeps its connection and terminal" "[ -f $L/moved.txt ] && grep -q '^right\*: sftp://' build/shots/reg-tabserver-panels.txt && grep -q '^left: .*/left |.*tabs: left$' build/shots/reg-tabserver-panels.txt"
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
# Resume after a break: a smaller file met by a server transfer (zeros in it, to
# tell an append from a new copy) is completed with "Resume" — SFTP and FTP, both ways.
scripts/test/mkdata.sh
resprep() { head -c 2000000 /dev/urandom > $L/big.dat; head -c 1000000 /dev/zero > $R/big.dat; head -c 2000000 /dev/urandom > $R/up.dat; head -c 1000000 /dev/zero > $L/up.dat; }
resumed() { [ "$(stat -f %z $1)" = 2000000 ] && [ "$(head -c 1000000 $1 | tr -d '\0' | wc -c | tr -d ' ')" = 0 ] && cmp -s <(tail -c +1000001 $1) <(tail -c +1000001 $2); }
resprep; run sres "$(connect sftp://oritest$PWD/$L) alt+b wait text:ig.dat escape f5 wait enter wait wait click:Resume wait wait wait"
check "SFTP: a download resumed" "resumed $R/big.dat $L/big.dat"
resprep; run sresup "$(connect sftp://oritest$PWD/$L) tab alt+u wait text:p.dat escape f5 wait enter wait wait click:Resume wait wait wait"
check "SFTP: an upload resumed" "resumed $L/up.dat $R/up.dat"
resprep; run fres "$(connect ftp://tester@127.0.0.1:2121/left 'text:secret enter wait') alt+b wait text:ig.dat escape f5 wait enter wait wait click:Resume wait wait wait"
check "FTP: a download resumed" "resumed $R/big.dat $L/big.dat"
resprep; run fresup "$(connect ftp://tester@127.0.0.1:2121/left 'text:secret enter wait') tab alt+u wait text:p.dat escape f5 wait enter wait wait click:Resume wait wait wait"
check "FTP: an upload resumed" "resumed $L/up.dat $R/up.dat"
resprep; cp $L/big.dat $R/big.dat
run snores "$(connect sftp://oritest$PWD/$L) alt+b wait text:ig.dat escape f5 wait enter wait wait"
check "No Resume for a file as big as the source" "grep -qx 'File already exists' build/shots/reg-snores-sheet2.txt && grep -qx '\[button\] Skip' build/shots/reg-snores-sheet2.txt && ! grep -qx '\[button\] Resume' build/shots/reg-snores-sheet2.txt"

scripts/test/servers.sh stop

echo "passed: $pass, failed: $fail"
[ $fail -eq 0 ]
