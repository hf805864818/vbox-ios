# -*- coding: utf-8 -*-
"""Crypto.PublicKey.RSA — 最小 pycryptodome 兼容层"""

import base64


class RsaKey:
    def __init__(self, n, e, d=None):
        self.n = n
        self.e = e
        self.d = d

    def has_private(self):
        return self.d is not None

    def size_in_bits(self):
        return self.n.bit_length()

    def size_in_bytes(self):
        return (self.size_in_bits() + 7) // 8


class _DerReader:
    def __init__(self, data):
        self.data = data
        self.pos = 0

    def read_tlv(self):
        if self.pos >= len(self.data):
            raise ValueError("Unexpected end of DER")
        tag = self.data[self.pos]
        self.pos += 1
        if self.pos >= len(self.data):
            raise ValueError("Invalid DER length")
        first = self.data[self.pos]
        self.pos += 1
        if first & 0x80:
            count = first & 0x7f
            if count == 0 or self.pos + count > len(self.data):
                raise ValueError("Invalid DER length")
            length = int.from_bytes(self.data[self.pos:self.pos + count], 'big')
            self.pos += count
        else:
            length = first
        if self.pos + length > len(self.data):
            raise ValueError("Truncated DER value")
        value = self.data[self.pos:self.pos + length]
        self.pos += length
        return tag, value


def _pem_to_der(data):
    if isinstance(data, str):
        data = data.encode('utf-8')
    data = bytes(data)
    if b'-----BEGIN' not in data:
        return data
    lines = data.replace(b'\r', b'').split(b'\n')
    body = [line.strip() for line in lines if line and not line.startswith(b'-----')]
    return base64.b64decode(b''.join(body))


def _read_seq(data):
    tag, value = _DerReader(data).read_tlv()
    if tag != 0x30:
        raise ValueError("Expected DER SEQUENCE")
    return _DerReader(value)


def _read_int(reader):
    tag, value = reader.read_tlv()
    if tag != 0x02:
        raise ValueError("Expected DER INTEGER")
    return int.from_bytes(value, 'big')


def _parse_pkcs1_private(der):
    r = _read_seq(der)
    _version = _read_int(r)
    n = _read_int(r)
    e = _read_int(r)
    d = _read_int(r)
    return RsaKey(n, e, d)


def _parse_pkcs1_public(der):
    r = _read_seq(der)
    n = _read_int(r)
    e = _read_int(r)
    return RsaKey(n, e)


def _parse_spki_public(der):
    r = _read_seq(der)
    r.read_tlv()  # AlgorithmIdentifier
    tag, bit_string = r.read_tlv()
    if tag != 0x03 or not bit_string:
        raise ValueError("Expected public key BIT STRING")
    return _parse_pkcs1_public(bit_string[1:])


def _parse_pkcs8_private(der):
    r = _read_seq(der)
    _version = _read_int(r)
    r.read_tlv()  # AlgorithmIdentifier
    tag, octets = r.read_tlv()
    if tag != 0x04:
        raise ValueError("Expected private key OCTET STRING")
    return _parse_pkcs1_private(octets)


def import_key(extern_key, passphrase=None):
    if passphrase:
        raise ValueError("Encrypted RSA keys are not supported")
    der = _pem_to_der(extern_key)
    parsers = (_parse_pkcs1_private, _parse_pkcs8_private, _parse_spki_public, _parse_pkcs1_public)
    last_error = None
    for parser in parsers:
        try:
            return parser(der)
        except Exception as exc:
            last_error = exc
    raise ValueError("RSA key format is not supported: %s" % last_error)
