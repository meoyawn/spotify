"""Independent aioquic HTTP/3 peer for local transport conformance only.

Setup: uv sync --project tools/oracles --locked
The server binds only 127.0.0.1. Certificates are generated for this run.
"""
import asyncio
import base64
from datetime import datetime, timedelta, timezone
import ipaddress
import json
import secrets
import shutil
from pathlib import Path
import tempfile

ROOT = Path(__file__).resolve().parents[2]
from aioquic.asyncio import QuicConnectionProtocol, serve
from aioquic.h3.connection import H3Connection, H3_ALPN
from aioquic.h3.events import HeadersReceived, DataReceived
from aioquic.quic.configuration import QuicConfiguration
from aioquic.buffer import Buffer
from aioquic.quic.packet import pull_quic_transport_parameters
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import ExtendedKeyUsageOID, NameOID


class ObservedH3Connection(H3Connection):
    def __init__(self, *args, **kwargs):
        self.client_control_frames = []
        super().__init__(*args, **kwargs)

    def _handle_control_frame(self, frame_type, frame_data):
        # Observe the actual decoded stream before the standard parser handles
        # it. Neither the frame nor its permission/meaning is substituted.
        observed = {'type': int(frame_type), 'length': len(frame_data)}
        if int(frame_type) == 0x0f0700:
            # Decode the actual RFC9218 request-stream PRIORITY_UPDATE payload
            # with the independent peer's standard QUIC varint reader.
            payload = Buffer(data=frame_data)
            observed['prioritizedElementId'] = payload.pull_uint_var()
            value = payload.pull_bytes(payload.capacity - payload.tell())
            observed['priorityFieldValue'] = value.decode('ascii')
        self.client_control_frames.append(observed)
        return super()._handle_control_frame(frame_type, frame_data)


class EchoProtocol(QuicConnectionProtocol):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.http = ObservedH3Connection(self._quic)
        self.identifier = secrets.token_hex(8)
        self.requests = {}
        self.rejected_uploads = set()
        self.client_transport_parameters = {}
        original_parse = self._quic._parse_transport_parameters
        def observe_parameters(data, from_session_ticket=False):
            if not from_session_ticket:
                decoded = pull_quic_transport_parameters(Buffer(data=data))
                self.client_transport_parameters = {name: getattr(decoded, name) for name in (
                    'max_idle_timeout', 'max_udp_payload_size', 'initial_max_data',
                    'initial_max_stream_data_bidi_local', 'initial_max_stream_data_bidi_remote',
                    'initial_max_stream_data_uni', 'initial_max_streams_bidi', 'initial_max_streams_uni',
                    'max_datagram_frame_size')}
            return original_parse(data, from_session_ticket=from_session_ticket)
        self._quic._parse_transport_parameters = observe_parameters

    def quic_event_received(self, event):
        for item in self.http.handle_event(event):
            if isinstance(item, HeadersReceived):
                if dict(item.headers).get(b":path") == b"/early-response":
                    self.rejected_uploads.add(item.stream_id)
                    self.http.send_headers(item.stream_id, [(b":status", b"413"),
                        (b"content-length", b"0")], end_stream=True)
                    self._quic.stop_stream(item.stream_id, 0x100)
                    self.transmit()
                    continue
                self.requests[item.stream_id] = {"headers": item.headers, "body": bytearray(),
                    "headersEndStream": item.stream_ended}
            elif isinstance(item, DataReceived):
                if item.stream_id in self.rejected_uploads:
                    continue
                self.requests[item.stream_id]["body"].extend(item.data)
            if isinstance(item, (HeadersReceived, DataReceived)) and item.stream_ended:
                self.respond(item.stream_id)

    def respond(self, stream_id):
        request = self.requests.pop(stream_id)
        path = dict(request["headers"])[b":path"]
        if path == b"/hang":
            return
        if path == b"/reset":
            self._quic.reset_stream(stream_id, 0x10c)
            self.transmit()
            return
        if path == b"/redirect":
            self.http.send_headers(stream_id, [(b":status", b"302"),
                (b"location", b"https://accounts.spotify.com/must-not-follow")], end_stream=True)
        elif path.startswith(b"/length/"):
            lengths = {
                b"/length/truncated": [b"100"],
                b"/length/excess": [b"0"],
                b"/length/invalid": [b"invalid"],
                b"/length/conflicting": [b"1", b"2"],
                b"/length/repeated": [b"1", b"1"],
            }[path]
            self.http.send_headers(stream_id, [(b":status", b"200")] +
                [(b"content-length", length) for length in lengths])
            self.http.send_data(stream_id, b"x", end_stream=True)
        elif path in (b"/representation-length", b"/not-modified", b"/no-content"):
            status = {b"/representation-length": b"200", b"/not-modified": b"304",
                b"/no-content": b"204"}[path]
            headers = [(b":status", status)]
            if status != b"204":
                headers.append((b"content-length", b"37"))
            self.http.send_headers(stream_id, headers, end_stream=True)
        elif path == b"/forbidden-body":
            self.http.send_headers(stream_id, [(b":status", b"204")])
            self.http.send_data(stream_id, b"x", end_stream=True)
        else:
            body = json.dumps({"protocol": "h3", "streamId": stream_id,
                "connectionId": self.identifier,
                "clientHttp3Settings": {str(key): value for key, value in (self.http.received_settings or {}).items()},
                "clientHttp3SettingsSequence": [list(item) for item in (self.http.received_settings or {}).items()],
                "clientControlFrames": self.http.client_control_frames,
                "clientQuicTransportParameters": self.client_transport_parameters,
                "peerQpackEncoderBytesSent": self.http._encoder_bytes_sent,
                "peerQpackDecoderBytesReceived": self.http._decoder_bytes_received,
                **request.get("peerObservation", {}),
                "headers": [[k.decode("ascii"), v.decode("latin1")] for k, v in request["headers"]],
                "bodyBase64": base64.b64encode(request["body"]).decode("ascii")},
                separators=(",", ":")).encode("utf8")
            self.http.send_headers(stream_id, [(b":status", b"200"),
                (b"content-type", b"application/json"),
                (b"x-qpack-conformance", b"repeated response field for negotiated dynamic table"),
                (b"content-length", str(len(body)).encode("ascii"))])
            self.http.send_data(stream_id, body, end_stream=True)
        self.transmit()
        if path == b"/close":
            asyncio.get_running_loop().call_later(0.05, self.close)


def certificate(directory):
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    subject = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "localhost")])
    now = datetime.now(timezone.utc)
    cert = (x509.CertificateBuilder().subject_name(subject).issuer_name(subject)
        .public_key(key.public_key()).serial_number(x509.random_serial_number())
        .not_valid_before(now - timedelta(minutes=1)).not_valid_after(now + timedelta(days=1))
        .add_extension(x509.SubjectAlternativeName([x509.DNSName("localhost"),
            x509.IPAddress(ipaddress.ip_address("127.0.0.1"))]), critical=False)
        .add_extension(x509.BasicConstraints(ca=True, path_length=0), critical=True)
        .add_extension(x509.ExtendedKeyUsage([ExtendedKeyUsageOID.SERVER_AUTH]), critical=False)
        .sign(key, hashes.SHA256()))
    cert_path, key_path = directory / "cert.pem", directory / "key.pem"
    cert_path.write_bytes(cert.public_bytes(serialization.Encoding.PEM))
    key_path.write_bytes(key.private_bytes(serialization.Encoding.PEM,
        serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
    key_path.chmod(0o600)
    return cert_path, key_path


async def main():
    parent = ROOT / ".local/http3-peer"
    parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    directory = Path(tempfile.mkdtemp(prefix="peer-", dir=parent))
    cert, key = certificate(directory)
    other_cert, _ = certificate(directory / "untrusted")
    config = QuicConfiguration(is_client=False, alpn_protocols=H3_ALPN)
    config.load_cert_chain(str(cert), str(key))
    server = await serve("127.0.0.1", 0, configuration=config, create_protocol=EchoProtocol)
    port = server._transport.get_extra_info("sockname")[1]
    print(json.dumps({"port": port, "certificate": str(cert),
        "untrustedCertificate": str(other_cert)}), flush=True)
    try:
        await asyncio.Future()
    finally:
        server.close()
        shutil.rmtree(directory)


if __name__ == "__main__":
    asyncio.run(main())
