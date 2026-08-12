# -*- coding: utf-8 -*-
"""Crypto.Cipher.PKCS1_v1_5 — 最小 pycryptodome 兼容层"""

import os


class PKCS115_Cipher:
    def __init__(self, key):
        self._key = key

    def encrypt(self, message):
        message = bytes(message)
        k = self._key.size_in_bytes()
        if len(message) > k - 11:
            raise ValueError("Plaintext is too long.")

        padding_len = k - len(message) - 3
        padding = bytearray()
        while len(padding) < padding_len:
            chunk = os.urandom(padding_len - len(padding))
            padding.extend(b for b in chunk if b != 0)
        em = b'\x00\x02' + bytes(padding[:padding_len]) + b'\x00' + message
        m = int.from_bytes(em, 'big')
        c = pow(m, self._key.e, self._key.n)
        return c.to_bytes(k, 'big')

    def decrypt(self, ciphertext, sentinel, expected_pt_len=0):
        if not self._key.has_private():
            raise TypeError("This is not a private key")
        k = self._key.size_in_bytes()
        ciphertext = bytes(ciphertext)
        if len(ciphertext) != k:
            return sentinel

        c = int.from_bytes(ciphertext, 'big')
        m = pow(c, self._key.d, self._key.n)
        em = m.to_bytes(k, 'big')
        if len(em) < 11 or not em.startswith(b'\x00\x02'):
            return sentinel
        sep = em.find(b'\x00', 2)
        if sep < 10:
            return sentinel
        message = em[sep + 1:]
        if expected_pt_len and len(message) != expected_pt_len:
            return sentinel
        return message


def new(key, randfunc=None):
    return PKCS115_Cipher(key)
