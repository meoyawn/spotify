"""Independent same-authority TLS H2 / QUIC H3 peer with an Alt-Svc response."""
import asyncio
import base64
import json
from itertools import count
from pathlib import Path
import ssl
import sys
import tempfile
import threading

from aioquic.asyncio import serve
from aioquic.quic.configuration import QuicConfiguration
from aioquic.h3.connection import H3_ALPN
from http3_loopback_server import EchoProtocol, certificate
from native_cef_h2_peer import H2CaptureServer


class QuicReceiveGate:
    def __init__(self):
        self.open = False
        self.pending = []

    def receive(self, callback, data, addr):
        if self.open:
            callback(data, addr)
        elif len(self.pending) < 128:
            self.pending.append((callback, data, addr))

    def release(self):
        self.open = True
        pending, self.pending = self.pending, []
        for callback, data, addr in pending:
            callback(data, addr)


async def start(directory, *, advertise=True, captures=None, quic_gate=None, cors_response=None,
        quic_observation=None):
    cert, key = certificate(directory)
    tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    tls.load_cert_chain(cert, key)
    tls.set_alpn_protocols(['h2'])
    ordinals = count(1)
    def capture_h2(item):
        item['peerObservation'] = {'requestCount': next(ordinals)}
        if captures is not None:
            captures.append({'protocol': 'h2', **item})
    def response_h2(item):
        if cors_response is not None and dict(item['headers']).get(':method') == 'OPTIONS':
            return cors_response['statusCode'], [(key, value) for key, value in cors_response['headersInDecodedOrder']
                if key != 'content-length'], b''
        return None
    peer = H2CaptureServer(tls, echo_body=True, on_capture=capture_h2, response_factory=response_h2)
    port = peer.server_address[1]
    if advertise:
        peer.response_headers = [('alt-svc', f'h3=":{port}"; ma=2592000')]
    threading.Thread(target=peer.serve_forever, daemon=True).start()
    class CaptureH3(EchoProtocol):
        def __init__(self, *args, **kwargs):
            super().__init__(*args, **kwargs)
            if quic_observation is not None:
                quic_observation['connections'] += 1

        def datagram_received(self, data, addr):
            if quic_gate is None:
                super().datagram_received(data, addr)
            else:
                quic_gate.receive(super().datagram_received, data, addr)

        def respond(self, stream_id):
            self.requests[stream_id]['peerObservation'] = {'requestCount': next(ordinals)}
            if captures is not None:
                captures.append({'protocol': 'h3', 'headers': [[key.decode(), value.decode()]
                    for key, value in self.requests[stream_id]['headers']],
                    'bodyBase64': base64.b64encode(self.requests[stream_id]['body']).decode(),
                    'headersEndStream': self.requests[stream_id]['headersEndStream']})
            if cors_response is not None and dict(self.requests[stream_id]['headers']).get(b':method') == b'OPTIONS':
                self.requests.pop(stream_id)
                self.http.send_headers(stream_id, [(b':status', str(cors_response['statusCode']).encode()),
                    *[(key.encode(), value.encode()) for key, value in cors_response['headersInDecodedOrder']]],
                    end_stream=True)
                self.transmit()
                return
            super().respond(stream_id)
    config = QuicConfiguration(is_client=False, alpn_protocols=H3_ALPN)
    config.load_cert_chain(str(cert), str(key))
    quic = await serve('127.0.0.1', port, configuration=config, create_protocol=CaptureH3)
    return peer, quic, port, cert


async def main():
    with tempfile.TemporaryDirectory(prefix='spotify-protocol-peer-') as root:
        gate = QuicReceiveGate() if '--hold-quic' in sys.argv else None
        cors = '--renderer-preflight' in sys.argv
        records = [] if cors else None
        response = None
        if cors:
            fixture = json.loads((Path(__file__).resolve().parents[2] /
                'reverse-engineering/fixtures/native-renderer-preflight.json').read_text())
            response = fixture['responseProfiles'][0]['value']
        quic_observation = {'connections': 0}
        peer, quic, port, cert = await start(Path(root), quic_gate=gate, captures=records,
            cors_response=response, quic_observation=quic_observation)
        untrusted, _ = certificate(Path(root) / 'untrusted')
        print(json.dumps({'port': port, 'certificate': str(cert),
            'untrustedCertificate': str(untrusted)}), flush=True)
        try:
            while True:
                line = await asyncio.to_thread(sys.stdin.readline)
                if not line or line.strip() == 'stop':
                    break
                if line.strip() == 'allow-quic' and gate is not None:
                    gate.release()
                    print(json.dumps({'quicGateOpened': True}), flush=True)
                if line.strip() == 'quic-state':
                    print(json.dumps({'quicConnections': quic_observation['connections']}), flush=True)
                if line.strip() == 'captures' and records is not None:
                    print(json.dumps({'captures': [{key: row[key] for key in
                        ['protocol', 'headers', 'bodyBase64', 'headersEndStream']} for row in records]}), flush=True)
        finally:
            if gate is not None:
                gate.release()
            quic.close()
            await asyncio.to_thread(peer.shutdown)
            peer.server_close()


if __name__ == '__main__':
    asyncio.run(main())
