#!/bin/zsh
# Starts or stops the local test servers used by regress.sh (localhost only):
#   SFTP: a user-level sshd on 127.0.0.1:2222 (host alias "oritest" in build/sshtest/ssh_config)
#   FTP:  scripts/test/ftpd.py on 127.0.0.1:2121 (user tester, password secret, root build/testdata)
cd "$(dirname $0)/../.."
T=$PWD/build/sshtest
case "$1" in
start)
  if [ ! -f $T/client_ed25519 ]; then
    mkdir -p $T
    ssh-keygen -q -t ed25519 -N '' -f $T/host_ed25519
    ssh-keygen -q -t ed25519 -N '' -f $T/client_ed25519
    cp $T/client_ed25519.pub $T/authorized_keys
  fi
  cat > $T/sshd_config <<CONFIG
Port 2222
ListenAddress 127.0.0.1
HostKey $T/host_ed25519
AuthorizedKeysFile $T/authorized_keys
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
StrictModes no
PidFile $T/sshd.pid
Subsystem sftp /usr/libexec/sftp-server
LogLevel ERROR
CONFIG
  cat > $T/ssh_config <<CONFIG
Host oritest
  HostName 127.0.0.1
  Port 2222
  User $USER
  IdentityFile $T/client_ed25519
  IdentitiesOnly yes
  UserKnownHostsFile $T/known_hosts
  StrictHostKeyChecking accept-new
CONFIG
  chmod 600 $T/client_ed25519 $T/host_ed25519
  lsof -nP -iTCP:2222 -sTCP:LISTEN >/dev/null || (/usr/sbin/sshd -f $T/sshd_config -D -e > $T/sshd.log 2>&1 &)
  lsof -nP -iTCP:2121 -sTCP:LISTEN >/dev/null || (python3 scripts/test/ftpd.py $PWD/build/testdata 2121 > build/ftpd.log 2>&1 &)
  sleep 1
  ;;
stop)
  for port in 2222 2121; do
    for pid in $(lsof -nP -t -iTCP:$port -sTCP:LISTEN); do kill $pid; done
  done
  # ssh masters of test connections and their sshd sessions
  for pid in $(pgrep -f "build/sshtest/ssh"); do kill $pid; done
  ;;
esac
