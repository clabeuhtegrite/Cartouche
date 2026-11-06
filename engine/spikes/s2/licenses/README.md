# Licences of the libraries inside CPython for iOS

BeeWare's build of CPython for iOS (`PYTHON_SUPPORT` in [`runtime.env`](../runtime.env)) links these libraries into its extension modules, and ships none of their licence texts. They are copied here as their projects publish them, at the version that build uses, and [`build_ios_runtime.sh`](../build_ios_runtime.sh) puts them in the app, in `python/licenses`, with Python's, Capstone's and nxnative's, which it takes from their own sources.

| File | Library | Version | Licence | Taken from |
| --- | --- | --- | --- | --- |
| `bzip2.txt` | bzip2 | 1.0.8 | bzip2 licence (BSD-style) | `LICENSE` of [python/cpython-source-deps](https://github.com/python/cpython-source-deps/blob/bzip2-1.0.8/LICENSE), branch `bzip2-1.0.8` |
| `libffi.txt` | libffi | 3.4.7 | MIT | [`LICENSE`](https://github.com/libffi/libffi/blob/v3.4.7/LICENSE) at tag `v3.4.7` |
| `mpdecimal.txt` | mpdecimal | 4.0.0 | BSD-2-Clause | `COPYRIGHT.txt` of [python/cpython-source-deps](https://github.com/python/cpython-source-deps/blob/mpdecimal-4.0.0/COPYRIGHT.txt), branch `mpdecimal-4.0.0` |
| `openssl.txt` | OpenSSL | 3.5.9 | Apache-2.0 | [`LICENSE.txt`](https://github.com/openssl/openssl/blob/openssl-3.5.9/LICENSE.txt) at tag `openssl-3.5.9` |
| `xz.txt`, `xz-0BSD.txt` | XZ Utils (liblzma) | 5.6.4 | 0BSD | [`COPYING`](https://github.com/tukaani-project/xz/blob/v5.6.4/COPYING) and [`COPYING.0BSD`](https://github.com/tukaani-project/xz/blob/v5.6.4/COPYING.0BSD) at tag `v5.6.4` |

`libraries.txt` is the list of libraries in the `VERSIONS` file of that build. `build_ios_runtime.sh` stops when the build's list differs, so that a new release of Python-Apple-support brings the licences of its own libraries here first.
