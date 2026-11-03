"""Independent pinned hyper-h2 TLS peer for decoded outgoing request fields."""
import base64
import json
from itertools import count
from pathlib import Path
from queue import Empty, Queue
import socket
import socketserver
import ssl
import sys
import tempfile
import threading

from h2.config import H2Configuration
from h2.connection import H2Connection
from h2.events import DataReceived, RemoteSettingsChanged, RequestReceived, StreamEnded, WindowUpdated
from http3_loopback_server import certificate as create_certificate


class H2Handler(socketserver.BaseRequestHandler):
    def handle(self):
        connection_id = next(self.server.connection_ids)
        settings_sent = not self.server.defer_settings_until_request
        self.request.settimeout(15 if settings_sent else 0.25)
        connection = H2Connection(config=H2Configuration(client_side=False,
            header_encoding=None, normalize_inbound_headers=False))
        connection.initiate_connection()
        outgoing = bytearray(connection.data_to_send())
        if settings_sent:
            self.request.sendall(outgoing)
            outgoing.clear()
        streams, raw, held_responses = {}, bytearray(), {}
        initial_settings, initial_window_delta, startup = None, None, []
        try:
            while True:
                for stream_id, (gate, response) in list(held_responses.items()):
                    if gate.is_set():
                        connection.send_data(stream_id, response, end_stream=True)
                        del held_responses[stream_id]
                pending = connection.data_to_send()
                if pending:
                    self.request.sendall(pending)
                self.request.settimeout(0.05 if held_responses else 15 if settings_sent else 0.25)
                try:
                    data = self.request.recv(65536)
                except socket.timeout:
                    if settings_sent:
                        if held_responses:
                            continue
                        break
                    # Release the withheld preface so an unnecessary client
                    # SETTINGS wait is observable in the ordinary field capture.
                    self.request.sendall(outgoing)
                    outgoing.clear()
                    settings_sent = True
                    self.request.settimeout(15)
                    continue
                if not data:
                    break
                raw.extend(data)
                received_headers = False
                for event in connection.receive_data(data):
                    if isinstance(event, RemoteSettingsChanged) and initial_settings is None:
                        initial_settings = [[int(key), value.new_value] for key, value in event.changed_settings.items()]
                        startup.append('settings')
                    elif isinstance(event, WindowUpdated) and event.stream_id == 0 and initial_window_delta is None:
                        initial_window_delta = event.delta
                        startup.append('connection-window-update')
                    elif isinstance(event, RequestReceived):
                        if 'headers' not in startup:
                            startup.append('headers')
                        received_headers = True
                        priority = event.priority_updated
                        streams[event.stream_id] = {'alpn': self.request.selected_alpn_protocol(),
                            'connectionId': connection_id, 'streamId': event.stream_id,
                            'headersEndStream': event.stream_ended is not None,
                            'headersBeforeServerSettings': not settings_sent,
                            'clientInitialSettings': initial_settings,
                            'clientInitialConnectionWindowDelta': initial_window_delta,
                            'clientStartupOrder': list(startup),
                            'headersPriority': None if priority is None else {
                                'parentStreamId': priority.depends_on,
                                'weight': priority.weight, 'exclusive': priority.exclusive},
                            'headers': [[key.decode('latin1'), value.decode('latin1')] for key, value in event.headers],
                            'body': bytearray()}
                    elif isinstance(event, DataReceived):
                        streams[event.stream_id]['body'].extend(event.data)
                        connection.acknowledge_received_data(event.flow_controlled_length, event.stream_id)
                    elif isinstance(event, StreamEnded):
                        capture = streams.pop(event.stream_id)
                        capture['bodyBase64'] = base64.b64encode(capture.pop('body')).decode()
                        capture['rawClientFramesBase64'] = base64.b64encode(raw).decode()
                        self.server.captures.append(capture)
                        if self.server.on_capture:
                            self.server.on_capture(capture)
                        response = json.dumps({'protocol': 'h2', 'headers': capture['headers'],
                            'bodyBase64': capture['bodyBase64'],
                            **capture.get('peerObservation', {})}, separators=(',', ':')).encode() \
                            if self.server.echo_body else b''
                        overridden = self.server.response_factory(capture) if self.server.response_factory else None
                        status, response_headers = 200, self.server.response_headers
                        if overridden is not None:
                            status, response_headers, response = overridden
                        try:
                            gate = self.server.response_gates.get_nowait()
                        except Empty:
                            gate = None
                        connection.send_headers(event.stream_id, [(':status', str(status)),
                            ('content-length', str(len(response))), *response_headers],
                            end_stream=not response and gate is None)
                        if gate is not None:
                            held_responses[event.stream_id] = (gate, response)
                        elif response:
                            connection.send_data(event.stream_id, response, end_stream=True)
                outgoing.extend(connection.data_to_send())
                if outgoing and (settings_sent or received_headers):
                    self.request.sendall(outgoing)
                    outgoing.clear()
                    if not settings_sent:
                        settings_sent = True
                        self.request.settimeout(15)
        except (ConnectionError, TimeoutError, ssl.SSLError):
            pass


class H2CaptureServer(socketserver.ThreadingTCPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, tls, on_capture=None, *, defer_settings_until_request=False,
            response_headers=(), echo_body=False, response_factory=None):
        self.tls, self.captures, self.on_capture = tls, [], on_capture
        self.defer_settings_until_request = defer_settings_until_request
        self.response_headers, self.echo_body = response_headers, echo_body
        self.response_factory = response_factory
        self.response_gates = Queue()
        self.connection_ids = count(1)
        super().__init__(('127.0.0.1', 0), H2Handler)

    def get_request(self):
        connection, address = super().get_request()
        return self.tls.wrap_socket(connection, server_side=True), address


def certificate(root):
    root = Path(root)
    cert, key = create_certificate(root)
    tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    tls.load_cert_chain(cert, key)
    tls.set_alpn_protocols(['h2'])
    return tls, cert


def main():
    with tempfile.TemporaryDirectory(prefix='spotify-h2-peer-') as directory:
        tls, cert = certificate(directory)
        lock = threading.Lock()
        def publish(value):
            with lock:
                print(json.dumps(value), flush=True)
        peer = H2CaptureServer(tls, lambda capture: publish({'capture': capture}),
            defer_settings_until_request='--defer-settings-until-request' in sys.argv[1:])
        threading.Thread(target=peer.serve_forever, daemon=True).start()
        publish({'port': peer.server_address[1], 'certificate': str(cert)})
        held = []
        for line in sys.stdin:
            command = line.strip()
            if command == 'stop':
                break
            if command == 'hold-next':
                gate = threading.Event()
                held.append(gate)
                peer.response_gates.put(gate)
                publish({'control': command})
            elif command == 'release-responses':
                for gate in held:
                    gate.set()
                held.clear()
                publish({'control': command})
        for gate in held:
            gate.set()
        peer.shutdown()
        peer.server_close()


if __name__ == '__main__':
    main()
