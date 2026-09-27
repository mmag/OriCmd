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
run crc "alt+n wait text:otes escape cmd:cm_CRCcreate wait enter wait wait"
check "checksum file verifies with shasum" "(cd $L && shasum -a 256 -c notes.md.sha256 >/dev/null 2>&1)"

scripts/test/mkdata.sh
run mrt "plus wait cmd+a text:*.txt enter wait ctrl+m wait text:doc_[C] enter wait wait"
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

scripts/test/mkdata.sh
run clip "alt+n wait text:otes escape cmd+c tab cmd+v wait wait"
check "Cmd+C / Cmd+V copies" "cmp -s $L/notes.md $R/notes.md"

# Associations; the "*" entry keeps every other file away from real apps.
scripts/test/mkdata.sh
defaults write ru.themmag.OriCmd.tests FileAssociations -data $(python3 -c 'import json; print(json.dumps([
  {"id": "00000000-0000-0000-0000-000000000001", "mask": "*.txt", "open": "cp %N %N.opened", "view": "", "edit": "cp %P%N %P%N.edited"},
  {"id": "00000000-0000-0000-0000-000000000002", "mask": "*.md", "open": "", "view": "sh -c \x27cp \"$0\" \"$0.viewed\"\x27", "edit": ""},
  {"id": "00000000-0000-0000-0000-000000000003", "mask": "*", "open": "true", "view": "", "edit": "true"}]).encode().hex())')
run assoc "alt+r wait text:eadme escape f4 wait enter wait alt+n wait text:otes escape f3 wait wait"
check "associations for Enter / F3 / F4" "[ -f $L/readme.txt.opened ] && [ -f $L/readme.txt.edited ] && [ -f $L/notes.md.viewed ]"

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
scripts/test/servers.sh stop

echo "passed: $pass, failed: $fail"
[ $fail -eq 0 ]
