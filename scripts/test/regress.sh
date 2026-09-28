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

scripts/test/mkdata.sh
run delete "alt+s wait text:cript escape shift+f8 wait enter wait wait"
check "Shift+F8 deletes permanently" "[ ! -f $L/script.sh ]"

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
scripts/test/servers.sh stop

echo "passed: $pass, failed: $fail"
[ $fail -eq 0 ]
