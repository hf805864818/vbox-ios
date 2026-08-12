# -*- coding: utf-8 -*-
"""Crypto.Util.Padding — pycryptodome 兼容层"""


def pad(data_to_pad, block_size, style='pkcs7'):
    if block_size <= 0 or block_size > 255:
        raise ValueError("block_size must be between 1 and 255")
    data = bytes(data_to_pad)
    padding_len = block_size - (len(data) % block_size)
    style = (style or 'pkcs7').lower()
    if style == 'pkcs7':
        padding = bytes([padding_len]) * padding_len
    elif style == 'x923':
        padding = b'\x00' * (padding_len - 1) + bytes([padding_len])
    elif style == 'iso7816':
        padding = b'\x80' + b'\x00' * (padding_len - 1)
    else:
        raise ValueError("Unknown padding style")
    return data + padding


def unpad(padded_data, block_size, style='pkcs7'):
    data = bytes(padded_data)
    if not data:
        raise ValueError("Zero-length input cannot be unpadded")
    if block_size <= 0:
        raise ValueError("block_size must be positive")
    if len(data) % block_size:
        raise ValueError("Input data is not padded")

    style = (style or 'pkcs7').lower()
    if style == 'pkcs7':
        padding_len = data[-1]
        if padding_len < 1 or padding_len > min(block_size, len(data)):
            raise ValueError("Padding is incorrect.")
        if data[-padding_len:] != bytes([padding_len]) * padding_len:
            raise ValueError("PKCS#7 padding is incorrect.")
        return data[:-padding_len]

    if style == 'x923':
        padding_len = data[-1]
        if padding_len < 1 or padding_len > min(block_size, len(data)):
            raise ValueError("Padding is incorrect.")
        if data[-padding_len:-1] != b'\x00' * (padding_len - 1):
            raise ValueError("ANSI X.923 padding is incorrect.")
        return data[:-padding_len]

    if style == 'iso7816':
        marker = data.rfind(b'\x80')
        if marker < 0 or data[marker + 1:] != b'\x00' * (len(data) - marker - 1):
            raise ValueError("ISO 7816-4 padding is incorrect.")
        padding_len = len(data) - marker
        if padding_len < 1 or padding_len > min(block_size, len(data)):
            raise ValueError("Padding is incorrect.")
        return data[:marker]

    raise ValueError("Unknown padding style")
