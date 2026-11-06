"""The part of the lz4 package that nxnative's tools use, for CPython on iOS.

nso.py reads LZ4-compressed segments with lz4.block.decompress(). The lz4
package on PyPI is a C extension with no build for iOS, so the spike S2 app
carries this decoder of the LZ4 block format instead, in pure Python. On a
Mac, nxnative's tools keep using the lz4 package itself.
"""
