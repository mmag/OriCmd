#!/usr/bin/env python3
"""A tiny FTP server for OriCmd's tests: localhost only, passive mode, one user.

Usage: ftpd.py <root folder> [port] [user] [password]
The client cannot leave <root folder>.
"""
import os, socket, socketserver, stat, sys, threading, time

ROOT = os.path.realpath(sys.argv[1])
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 2121
USER = sys.argv[3] if len(sys.argv) > 3 else "tester"
PASSWORD = sys.argv[4] if len(sys.argv) > 4 else "secret"


class Session(socketserver.StreamRequestHandler):
    def reply(self, text):
        self.wfile.write((text + "\r\n").encode())

    def real(self, path):
        virtual = os.path.normpath(os.path.join(self.cwd, path)) if path else self.cwd
        full = os.path.realpath(os.path.join(ROOT, virtual.lstrip("/")))
        if full != ROOT and not full.startswith(ROOT + os.sep):
            raise PermissionError("outside root")
        return virtual, full

    def open_data(self):
        conn, _ = self.passive.accept()
        self.passive.close()
        self.passive = None
        return conn

    def handle(self):
        self.cwd, self.user, self.logged_in, self.passive, self.rename_from = "/", None, False, None, None
        self.reply("220 OriCmd test FTP")
        while True:
            line = self.rfile.readline()
            if not line:
                return
            line = line.decode("utf-8", "replace").rstrip("\r\n")
            command, _, arg = line.partition(" ")
            command = command.upper()
            try:
                if not self.dispatch(command, arg):
                    return
            except (FileNotFoundError, NotADirectoryError, PermissionError, IsADirectoryError, OSError) as error:
                self.reply("550 " + str(error))

    def dispatch(self, command, arg):
        if command == "USER":
            self.user = arg; self.reply("331 Password required")
        elif command == "PASS":
            if self.user == USER and arg == PASSWORD:
                self.logged_in = True; self.reply("230 Logged in")
            else:
                self.reply("530 Login incorrect")
        elif command == "QUIT":
            self.reply("221 Bye"); return False
        elif not self.logged_in:
            self.reply("530 Please login")
        elif command in ("SYST",):
            self.reply("215 UNIX Type: L8")
        elif command == "FEAT":
            self.reply("211-Features:\r\n MLSD\r\n SIZE\r\n MDTM\r\n REST STREAM\r\n UTF8\r\n211 End")
        elif command == "OPTS":
            self.reply("200 OK")
        elif command == "PWD":
            self.reply('257 "%s"' % self.cwd)
        elif command == "CWD":
            virtual, full = self.real(arg)
            if not os.path.isdir(full): raise NotADirectoryError(arg)
            self.cwd = virtual; self.reply("250 OK")
        elif command == "CDUP":
            self.cwd = os.path.dirname(self.cwd.rstrip("/")) or "/"; self.reply("250 OK")
        elif command == "TYPE":
            self.reply("200 OK")
        elif command in ("PASV", "EPSV"):
            self.passive = socket.socket(); self.passive.bind(("127.0.0.1", 0)); self.passive.listen(1)
            port = self.passive.getsockname()[1]
            if command == "EPSV":
                self.reply("229 Entering Extended Passive Mode (|||%d|)" % port)
            else:
                self.reply("227 Entering Passive Mode (127,0,0,1,%d,%d)" % (port >> 8, port & 255))
        elif command in ("LIST", "NLST", "MLSD"):
            path = "" if arg.startswith("-") else arg
            _, full = self.real(path)
            self.reply("150 Listing")
            conn = self.open_data()
            for name in sorted(os.listdir(full)):
                info = os.lstat(os.path.join(full, name))
                if command == "NLST":
                    text = name
                elif command == "MLSD":
                    kind = "dir" if stat.S_ISDIR(info.st_mode) else "file"
                    text = "type=%s;size=%d;modify=%s;UNIX.mode=%04o; %s" % (
                        kind, info.st_size, time.strftime("%Y%m%d%H%M%S", time.gmtime(info.st_mtime)),
                        stat.S_IMODE(info.st_mode), name)
                else:
                    text = "%s 1 owner group %d %s %s" % (
                        stat.filemode(info.st_mode), info.st_size,
                        time.strftime("%b %d %H:%M", time.localtime(info.st_mtime)), name)
                conn.sendall((text + "\r\n").encode())
            conn.close(); self.reply("226 Done")
        elif command == "REST":
            self.offset = int(arg); self.reply("350 Restarting at %d" % self.offset)
        elif command == "RETR":
            _, full = self.real(arg)
            offset, self.offset = getattr(self, "offset", 0), 0
            with open(full, "rb") as source:
                source.seek(offset)
                self.reply("150 Sending"); conn = self.open_data()
                conn.sendall(source.read()); conn.close()
            self.reply("226 Done")
        elif command in ("STOR", "APPE"):
            _, full = self.real(arg)
            self.reply("150 Receiving"); conn = self.open_data()
            with open(full, "ab" if command == "APPE" else "wb") as target:
                while True:
                    data = conn.recv(65536)
                    if not data: break
                    target.write(data)
            conn.close(); self.reply("226 Done")
        elif command == "SIZE":
            _, full = self.real(arg); self.reply("213 %d" % os.path.getsize(full))
        elif command == "MDTM":
            _, full = self.real(arg)
            self.reply("213 " + time.strftime("%Y%m%d%H%M%S", time.gmtime(os.path.getmtime(full))))
        elif command == "MKD":
            virtual, full = self.real(arg); os.mkdir(full); self.reply('257 "%s" created' % virtual)
        elif command == "RMD":
            _, full = self.real(arg); os.rmdir(full); self.reply("250 Removed")
        elif command == "DELE":
            _, full = self.real(arg); os.remove(full); self.reply("250 Deleted")
        elif command == "RNFR":
            _, self.rename_from = self.real(arg); self.reply("350 Ready")
        elif command == "RNTO":
            _, full = self.real(arg); os.rename(self.rename_from, full); self.reply("250 Renamed")
        elif command == "NOOP":
            self.reply("200 OK")
        else:
            self.reply("502 Not implemented")
        return True


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


if __name__ == "__main__":
    with Server(("127.0.0.1", PORT), Session) as server:
        server.serve_forever()
