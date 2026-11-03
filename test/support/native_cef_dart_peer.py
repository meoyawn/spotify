"""Independent TLS HTTP/1.1 peer for original-CEF versus Dart outgoing bytes.

Uses the existing raw peer and a fresh trusted localhost certificate. This
process loads no CEF library and connects to no remote endpoint. Expected
application fields remain the separately captured shipped-CEF fixtures.
"""
import base64
import json
import socketserver
import ssl
import sys
import tempfile
import threading
from pathlib import Path

from http3_loopback_server import certificate
from http1_capture import CaptureServer, ROOT


class PersistentCaptureHandler(socketserver.BaseRequestHandler):
    """Raw byte capture across successive requests on the same TLS socket."""
    def handle(self):
        # Leave room for the outgoing check to cross Dart's15s idle default.
        self.request.settimeout(30)
        with self.server.connection_lock:
            self.server.connection_count += 1
            socket_id = self.server.connection_count
        pending = b''
        while True:
            while b'\r\n\r\n' not in pending:
                chunk = self.request.recv(8192)
                if not chunk or len(pending) + len(chunk) > 65536:
                    return
                pending += chunk
            head, pending = pending.split(b'\r\n\r\n', 1)
            lines = head.split(b'\r\n')
            method, target, version = lines[0].decode('ascii').split(' ')
            headers = [line.decode('latin1').split(':', 1) for line in lines[1:]]
            length = int(next((v.strip() for k, v in headers if k.lower() == 'content-length'), '0'))
            if length < 0 or length > 1024 * 1024:
                return
            while len(pending) < length:
                chunk = self.request.recv(length - len(pending))
                if not chunk:
                    return
                pending += chunk
            body, pending = pending[:length], pending[length:]
            self.server.captures.append({'method': method, 'rawTarget': target, 'version': version,
                'headers': [[k, v.lstrip(' ')] for k, v in headers],
                'bodyBase64': base64.b64encode(body).decode(),
                'rawRequestBase64': base64.b64encode(head + b'\r\n\r\n' + body).decode(),
                'socketId': socket_id})
            self.request.sendall(b'HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n')


def main():
    with tempfile.TemporaryDirectory(prefix='cef-dart-peer-', dir=ROOT / '.local') as folder:
        cert, key = certificate(Path(folder))
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(cert, key)
        context.set_alpn_protocols(['http/1.1'])
        server = CaptureServer(context)
        if '--keepalive' in sys.argv:
            server.connection_lock = threading.Lock()
            server.connection_count = 0
            server.RequestHandlerClass = PersistentCaptureHandler
        threading.Thread(target=server.serve_forever, daemon=True).start()
        print(json.dumps({'origin': f'https://localhost:{server.server_address[1]}',
            'certificate': str(cert)}), flush=True)
        try:
            for line in sys.stdin:
                if line.strip() == 'stop':
                    break
                if line.strip() != 'capture' or not server.captures:
                    raise RuntimeError('Expected an already completed outgoing capture')
                print(json.dumps(server.captures.pop(0)), flush=True)
        finally:
            server.shutdown()
            server.server_close()


if __name__ == '__main__':
    main()
