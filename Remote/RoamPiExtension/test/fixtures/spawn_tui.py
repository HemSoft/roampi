"""Give a disposable Pi process a PTY without exposing terminal output."""
import os
import pty
import signal
import sys

pid, master = pty.fork()
if pid == 0:
    os.execvp(sys.argv[1], sys.argv[1:])

def stop(_signal, _frame):
    try:
        os.kill(pid, signal.SIGTERM)
    except ProcessLookupError:
        pass

signal.signal(signal.SIGTERM, stop)
try:
    while True:
        try:
            os.read(master, 8192)
        except OSError:
            break
finally:
    os.waitpid(pid, 0)
    os.close(master)
