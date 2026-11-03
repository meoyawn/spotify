"""Independent TLS peer: compressed OAuth nonce JSON drives outgoing retries."""
import base64
import gzip
import json
import socketserver
import ssl
import sys
import tempfile
import threading
import zlib

import brotli
import zstandard
from h2.config import H2Configuration
from h2.connection import H2Connection
from h2.events import DataReceived, RequestReceived, StreamEnded

from native_cef_h2_peer import certificate


class Peer(socketserver.ThreadingTCPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, tls, publish):
        self.tls, self.publish = tls, publish
        self.encoding, self.attempt = 'gzip', 0
        super().__init__(('127.0.0.1', 0), Handler)

    def get_request(self):
        connection, address = super().get_request()
        return self.tls.wrap_socket(connection, server_side=True), address

    def response(self, capture):
        self.attempt += 1
        capture.update(attempt=self.attempt, encoding=self.encoding)
        self.publish({'capture': capture})
        status = 400 if self.attempt == 1 else 200
        fields = {'error': 'use_dpop_nonce'} if status == 400 else {
            'access_token': 'access-fixture', 'expires_in': 3600, 'token_type': 'DPoP',
            'refresh_token': 'refresh-fixture', 'username': 'fixture-user'}
        body = json.dumps(fields, separators=(',', ':')).encode()
        encoded = {'gzip': lambda: gzip.compress(body, mtime=0),
            'deflate': lambda: zlib.compress(body),
            'deflate-raw': lambda: zlib.compress(body, wbits=-15),
            'br': lambda: brotli.compress(body),
            'zstd': lambda: zstandard.ZstdCompressor(write_checksum=True).compress(body)}[self.encoding]()
        coding = 'deflate' if self.encoding == 'deflate-raw' else self.encoding
        headers = [('content-type', 'application/json'), ('content-encoding', coding),
            ('content-length', str(len(encoded))), *([('dpop-nonce', '')] if status == 400 else [])]
        return status, headers, encoded


class Handler(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.settimeout(15)
        try:
            if self.request.selected_alpn_protocol() == 'h2':
                self.h2()
            else:
                self.h1()
        except (ConnectionError, TimeoutError, ssl.SSLError):
            pass

    def h1(self):
        data = b''
        while b'\r\n\r\n' not in data:
            chunk = self.request.recv(65536)
            if not chunk:
                return
            data += chunk
        head, body = data.split(b'\r\n\r\n', 1)
        lines = head.split(b'\r\n')
        method, target, version = lines[0].decode('ascii').split(' ')
        headers = [line.decode('latin1').split(':', 1) for line in lines[1:]]
        headers = [[name, value.lstrip(' ')] for name, value in headers]
        length = int(next((value for name, value in headers if name.lower() == 'content-length'), '0'))
        while len(body) < length:
            body += self.request.recv(length - len(body))
        status, response_headers, encoded = self.server.response({'protocol': 'http/1.1',
            'method': method, 'rawTarget': target, 'headers': headers,
            'bodyBase64': base64.b64encode(body).decode()})
        response = f'HTTP/1.1 {status} Fixture\r\n' + ''.join(f'{name}: {value}\r\n' for name, value in response_headers)
        self.request.sendall(response.encode() + b'Connection: close\r\n\r\n' + encoded)

    def h2(self):
        connection = H2Connection(config=H2Configuration(client_side=False,
            header_encoding=None, normalize_inbound_headers=False))
        connection.initiate_connection()
        self.request.sendall(connection.data_to_send())
        streams = {}
        while True:
            data = self.request.recv(65536)
            if not data:
                break
            for event in connection.receive_data(data):
                if isinstance(event, RequestReceived):
                    streams[event.stream_id] = {'protocol': 'h2', 'headers': [
                        [name.decode('latin1'), value.decode('latin1')] for name, value in event.headers], 'body': bytearray()}
                elif isinstance(event, DataReceived):
                    streams[event.stream_id]['body'].extend(event.data)
                    connection.acknowledge_received_data(event.flow_controlled_length, event.stream_id)
                elif isinstance(event, StreamEnded):
                    capture = streams.pop(event.stream_id)
                    capture['bodyBase64'] = base64.b64encode(capture.pop('body')).decode()
                    status, headers, encoded = self.server.response(capture)
                    connection.send_headers(event.stream_id, [(':status', str(status)), *headers])
                    connection.send_data(event.stream_id, encoded, end_stream=True)
            outgoing = connection.data_to_send()
            if outgoing:
                self.request.sendall(outgoing)


def main():
    with tempfile.TemporaryDirectory(prefix='cef-compressed-retry-') as directory:
        tls, cert = certificate(directory)
        tls.set_alpn_protocols(['h2', 'http/1.1'])
        lock = threading.Lock()
        def publish(value):
            with lock:
                print(json.dumps(value), flush=True)
        peer = Peer(tls, publish)
        threading.Thread(target=peer.serve_forever, daemon=True).start()
        publish({'port': peer.server_address[1], 'certificate': str(cert)})
        for line in sys.stdin:
            if line.strip() == 'stop':
                break
            peer.encoding, peer.attempt = json.loads(line)['encoding'], 0
            publish({'configured': peer.encoding})
        peer.shutdown()
        peer.server_close()


if __name__ == '__main__':
    main()
