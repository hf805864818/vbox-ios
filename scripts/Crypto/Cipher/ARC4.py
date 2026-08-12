# -*- coding: utf-8 -*-
"""Crypto.Cipher.ARC4 — pycryptodome 兼容层

纯 Python 实现 RC4 (ARC4) 流密码，无 C 扩展依赖。
兼容 API:
    from Crypto.Cipher import ARC4
    cipher = ARC4.new(key)
    encrypted = cipher.encrypt(data)
    decrypted = cipher.decrypt(data)

RC4 是流密码，encrypt/decrypt 是同一操作 (XOR keystream)。
"""


class _ARC4Cipher:
    """ARC4 加解密对象 — 兼容 pycryptodome 的 cipher 对象"""

    def __init__(self, key):
        self._key = bytes(key)
        self._s = list(range(256))
        self._i = 0
        self._j = 0
        self._init_sbox()

    def _init_sbox(self):
        """KSA (Key-Scheduling Algorithm)"""
        j = 0
        for i in range(256):
            j = (j + self._s[i] + self._key[i % len(self._key)]) & 0xFF
            self._s[i], self._s[j] = self._s[j], self._s[i]

    def _prga(self, data):
        """PRGA (Pseudo-Random Generation Algorithm) + XOR"""
        out = bytearray(len(data))
        s = self._s
        i = self._i
        j = self._j
        for n in range(len(data)):
            i = (i + 1) & 0xFF
            j = (j + s[i]) & 0xFF
            s[i], s[j] = s[j], s[i]
            k = s[(s[i] + s[j]) & 0xFF]
            out[n] = data[n] ^ k
        self._i = i
        self._j = j
        return bytes(out)

    def encrypt(self, data):
        return self._prga(bytes(data))

    def decrypt(self, ciphertext):
        return self._prga(bytes(ciphertext))


def new(key, *args, **kwargs):
    """创建 ARC4 cipher 对象 — 兼容 pycryptodome 的 ARC4.new()

    Args:
        key: 密钥 (bytes)

    Returns:
        _ARC4Cipher 对象
    """
    return _ARC4Cipher(key)
