# send.py HOST PORT: the test's lines over one TCP connection, as Talos sends.
import socket, sys
sys.path.insert(0, "/t")
import lines

with socket.create_connection((sys.argv[1], int(sys.argv[2])), timeout=10) as s:
    for l in lines.lines():
        s.sendall(l.encode())
