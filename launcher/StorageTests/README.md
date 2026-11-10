# Storage tests

The launcher's storage code, the code the app runs to reach the player's servers, run against real servers on a Mac: Samba for SMB, MinIO for S3, pyftpdlib for FTP, OpenSSH for SFTP. The unit tests of `launcher/Tests` check the protocols' messages; these check what the app does with them, from signing in to putting a game's IPA there and installing it again. The [Storage](../../.github/workflows/storage.yml) workflow runs them on GitHub's Mac (`xcode-27`) for each pull request that changes that code, its tests or the servers, and on main after one.

No game is involved: the IPAs are made-up apps of a few files ([`make_ipas.py`](make_ipas.py)), packed by nxnative's own [`pack_ipa.py`](https://github.com/seedds/nxnative/blob/main/dm/ios/tools/pack_ipa.py), at the commit Cartouche pins ([`catalog/nxnative.commit`](../../catalog/nxnative.commit)), as it packs games: folders, Unix modes, a link, an empty file, names with accents, small files deflated and large ones stored. One is about 35 MB, with files larger than a read of the storage; the other is past 4 GiB, as a game's is, with a file that lies past 4 GiB in it (Zip64).

## What runs

The package builds the launcher's own files, linked from [`Sources/CartoucheStorage`](Sources/CartoucheStorage), with SMBClient from `app/SMBClient` and swift-nio-ssh pinned as the app pins them ([`Package.resolved`](Package.resolved), the one of [`app/patches/livecontainer/0007`](../../app/patches/livecontainer/0007-link-the-swift-nio-ssh-package.patch)). [`app/tests/test_storage_tests.py`](../../app/tests/test_storage_tests.py) checks both, and that every storage file of the launcher but its views is linked.

[`StorageServerTests`](Tests/CartoucheStorageTests/StorageServerTests.swift) holds what every server goes through, each step as the app takes it:

- signing in, and refusing a wrong password or wrong keys as soon as the server says no, within 20 seconds;
- the games folder as the library lists it, with sizes and times, the folder one level down, no hidden file, and each IPA's `Info.plist` read where it sits, with the build it names;
- Install from: the IPA unpacked in one pass from the server, every file as it was, links and executables too, and, on SMB and SFTP, the connection cut on the way and the install reading on from where it stopped on a new one (CartoucheResumingSource);
- Copy to: the installed app written back as an IPA, then installed again from there; a file replaced only once the new one is finished, while another connection still reads the old one; nothing left of a copy given up;
- folders made, again, and removed; save copies written as zips, the oldest removed, the newest put back;
- where the account can write and where it cannot, as the app asks it, leaving nothing behind, and an install from a place it can only read;
- the IPA past 4 GiB: installed, with the memory the test takes measured all along, which must stay within 256 MiB of where it started, then copied back and read again past 4 GiB.

Each server adds what only it has:

| Case | Server | Also |
| --- | --- | --- |
| `SMBTests` | Samba | the shared folders the player picks from; a shared folder the account can only read, as the server says when Cartouche connects (MaximalAccess); a folder of root's in the player's; signing in as a guest; the room left |
| `S3Tests` | MinIO, in the region `eu-west-3` | keys that can only list and read; no keys, unknown keys; no region given, which MinIO names on the first request |
| `FTPTests` | pyftpdlib, with MLSD | an account that can only read; a folder it can only read; no user name; MLSD used for listing |
| `FTPListTests` | pyftpdlib, without MLSD or MLST | as `FTPTests`, listed with LIST, as vsftpd and others do |
| `SFTPTests` | OpenSSH | the server's key taken the first time; another key refused before the password is sent, as sshd's log shows; a wrong password said to be one |

## Running them

[`servers.sh`](servers.sh) starts the servers on 127.0.0.1, puts the IPAs in each, and writes `servers.json`, which tells the tests where each server is and its accounts:

```sh
brew install samba minio minio-mc
launcher/StorageTests/servers.sh start /tmp/cartouche-servers --big-mib 4112
CARTOUCHE_STORAGE_SERVERS=/tmp/cartouche-servers/servers.json swift test --package-path launcher/StorageTests
launcher/StorageTests/servers.sh stop /tmp/cartouche-servers
```

It adds a user, `cartouche-test`, and runs smbd and sshd as root with sudo, so it runs only on a throwaway Mac, as GitHub's are, or with `CARTOUCHE_STORAGE_THROWAWAY=1`; `stop` removes the user. The passwords and keys are made up at each start and stay in `servers.json`. Without `CARTOUCHE_STORAGE_SERVERS`, every test is skipped. The IPA past 4 GiB is made only when the disk has room for it four times over, else its test is skipped.

| Server | Port | Accounts | Games folder |
| --- | --- | --- | --- |
| Samba | 4450 | `cartouche-test`; guests on `Invités` | `Jeux` in the shared folder `Partage`, and in `Lecture seule` and `Invités`, which they can only read |
| MinIO | 9000 | the player's keys, and a reader's | `Jeux` in the bucket `cartouche` |
| pyftpdlib | 2121, 2122 without MLSD | `joueur`, and `lecteur`, which only reads | `Jeux` at the root |
| OpenSSH | 2222 | `cartouche-test`, by password | `Jeux` in its home |

Each root also has `Lecture seule`, a folder the player's account can only read, with the small IPA.

Samba on a Mac needs two things a NAS does not. It makes a new folder under a temporary name, then renames it over an empty one of its name, as macOS has no `renameat2(RENAME_NOREPLACE)`, and macOS refuses that rename, as OpenBSD does ([Samba's bug 15801](https://bugzilla.samba.org/show_bug.cgi?id=15801)): `servers.sh` sets `vfs mkdir use tmp name = no`. And smbd, when it stops, stops every process of its process group: `servers.sh` starts it in a group of its own, not the runner's.

## Not here

What needs an iPhone: Bonjour, the keychain, folders picked in Files, and the views. Nor the servers of NAS makers as they are configured out of the box; a NAS that behaves differently is worth a case here.
