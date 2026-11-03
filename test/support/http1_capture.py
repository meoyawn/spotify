"""Independent local HTTP/1 byte capture for protocol verification."""
import base64
import socketserver
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class CaptureHandler(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.settimeout(10)
        data = b''
        while b'\r\n\r\n' not in data:
            chunk = self.request.recv(8192)
            if not chunk or len(data) + len(chunk) > 65536:
                return
            data += chunk
        head, body = data.split(b'\r\n\r\n', 1)
        lines = head.split(b'\r\n')
        method, target, version = lines[0].decode('ascii').split(' ')
        headers = [line.decode('latin1').split(':', 1) for line in lines[1:]]
        length = int(next((value.strip() for key, value in headers if key.lower() == 'content-length'), '0'))
        while len(body) < length:
            chunk = self.request.recv(length - len(body))
            if not chunk:
                break
            body += chunk
        capture = {'method': method, 'rawTarget': target, 'version': version,
            'headers': [[key, value.lstrip(' ')] for key, value in headers],
            'bodyBase64': base64.b64encode(body).decode(),
            'rawRequestBase64': base64.b64encode(head + b'\r\n\r\n' + body).decode()}
        self.server.captures.append(capture)
        self.request.sendall(b'HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n')


class CaptureServer(socketserver.ThreadingTCPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, context=None):
        self.context, self.captures = context, []
        super().__init__(('127.0.0.1', 0), CaptureHandler)

    def get_request(self):
        connection, address = super().get_request()
        if self.context:
            connection = self.context.wrap_socket(connection, server_side=True)
        return connection, address
