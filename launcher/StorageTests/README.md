# Storage tests

The launcher's storage code, the code the app runs to reach the player's servers, run against real servers on a Mac: Samba for SMB, MinIO for S3, pyftpdlib for FTP, OpenSSH for SFTP, and a Mac of Cartouche Builder's that the tests play themselves. Google Drive cannot run on a Mac: [`drive_server.py`](drive_server.py) stands in for Google's servers, the sign-in of the player's own OAuth client and the Drive API, answering as Google's documentation says they do. The unit tests of `launcher/Tests` check the protocols' messages; these check what the app does with them, from signing in to putting a game's IPA there and installing it again. The [Storage](../../.github/workflows/storage.yml) workflow runs them on GitHub's Mac (`xcode-27`) for each pull request that changes that code, its tests or the servers, and on main after one.

No game is involved: the IPAs are made-up apps of a few files ([`make_ipas.py`](make_ipas.py)), packed by nxnative's own [`pack_ipa.py`](https://github.com/seedds/nxnative/blob/main/dm/ios/tools/pack_ipa.py), at the commit Cartouche pins ([`catalog/nxnative.commit`](../../catalog/nxnative.commit)), as it packs games: folders, Unix modes, a link, an empty file, names with accents, small files deflated and large ones stored. One is about 35 MB, with files larger than a read of the storage; the other is past 4 GiB, as a game's is, with a file that lies past 4 GiB in it (Zip64).

## What runs

The package builds the launcher's own files, linked from [`Sources/CartoucheStorage`](Sources/CartoucheStorage), with SMBClient from `app/SMBClient` and swift-nio-ssh pinned as the app pins them ([`Package.resolved`](Package.resolved), the one of [`app/patches/livecontainer/0007`](../../app/patches/livecontainer/0007-link-the-swift-nio-ssh-package.patch)). [`app/tests/test_storage_tests.py`](../../app/tests/test_storage_tests.py) checks both, and that every storage file of the launcher but its views is linked.

[`StorageServerTests`](Tests/CartoucheStorageTests/StorageServerTests.swift) holds what every server goes through, each step as the app takes it:

- signing in, and refusing a wrong password or wrong keys as soon as the server says no, within 20 seconds;
- the games folder as the library lists it, with sizes and times, the folder one level down, no hidden file, and each IPA's `Info.plist` read where it sits, with the build it names;
- Install from: the IPA unpacked in one pass from the server, every file as it was, links and executables too, and, on SMB and SFTP, the connection cut on the way and the install reading on from where it stopped on a new one (CartoucheResumingSource);
- Copy to: the installed app written back as an IPA, then installed again from there; a file replaced only once the new one is finished, while another connection still reads the old one; nothing left of a copy given up;
- folders made, again, and removed;
- a game's saves kept in step between two iPhones through the saves folder, as the app keeps them ([`CartoucheStorageSaves.swift`](../Sources/CartoucheStorageSaves.swift)): sent, then brought whole to an iPhone that has none, as after Cartouche is installed again; the newer ones fetched after reading what a copy holds from its end alone; when both iPhones played, the saves written last winning and the others kept as a copy of their own date; a copy put back becoming the newest, which the other iPhone takes; and the ten newest copies kept, the one just made among them;
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
| `DriveTests` | the stand-in for Google's servers | the sign-in on Google's page with the player's own client and PKCE, a sign-in asked again when Google gives no lasting one, the Drive left unchecked, the access refused, a client Google does not know; the access token renewed after its hour; a sign-in Google ended, as it does after seven days for a project in testing, waiting for the player to sign in again, with nothing more sent to Google and no report; a Google Doc, a shortcut, the bin and a name with a `/` left out of the games folder, the newest of two IPAs of one name taken, a name a Mac decomposed found; the room left; Google failing for a moment, asked again; an upload cut, by an error or a closed connection, going on from where Google holds it; the Drive API off in the player's project, said with where to turn it on; a full Drive; no redirection followed, so that the token goes to Google alone |

[`OfflineTests`](Tests/CartoucheStorageTests/OfflineTests.swift) needs none of these servers: it signs in to a server out of reach, as a NAS at home is from anywhere else, on every protocol, and to a port of the Mac that refuses the connection. Each must say the server is offline (CartoucheStorageReach): within the patience and four seconds for an address that never answers (`192.0.2.1`, which no network routes, RFC 5737), within four seconds for a refused connection. It also knocks on a server of the Mac without a word, and checks that a server tried again tells once that it answers again, then that it is offline once it stops.

[`MacBridgeTests`](Tests/CartoucheStorageTests/MacBridgeTests.swift) needs no server: it plays Cartouche Builder's side of the bridge itself ([`CartoucheBridge.swift`](../Sources/CartoucheBridge.swift)), on the loopback, with its Games and Saves folders in memory, and goes through what a player does with their Mac:

- pairing once, with the six digits both sides show, then signing in again at the address the Mac was last reached at;
- a pairing the Mac refuses, a Mac that removed this iPhone and another Mac at the old address, each said in the player's words, the last two asking to pair again;
- a Mac gone, said to be offline within the few seconds Cartouche gives it;
- an IPA read ahead in several pieces and a save copied both ways, a copy given up, folders made and removed, the room left, and a file the Mac does not have.

## Running them

[`servers.sh`](servers.sh) starts the servers on 127.0.0.1, puts the IPAs in each, and writes `servers.json`, which tells the tests where each server is and its accounts:

```sh
brew install samba minio minio-mc
launcher/StorageTests/servers.sh start /tmp/cartouche-servers --big-mib 4112
CARTOUCHE_STORAGE_SERVERS=/tmp/cartouche-servers/servers.json swift test --package-path launcher/StorageTests
launcher/StorageTests/servers.sh stop /tmp/cartouche-servers
```

The stand-in needs nothing but Python 3. It adds a user, `cartouche-test`, and runs smbd and sshd as root with sudo, so it runs only on a throwaway Mac, as GitHub's are, or with `CARTOUCHE_STORAGE_THROWAWAY=1`; `stop` removes the user. The passwords and keys are made up at each start and stay in `servers.json`. Without `CARTOUCHE_STORAGE_SERVERS`, every test but `OfflineTests` and `MacBridgeTests` is skipped. The IPA past 4 GiB is made only when the disk has room for it four times over, else its test is skipped.

| Server | Port | Accounts | Games folder |
| --- | --- | --- | --- |
| Samba | 4450 | `cartouche-test`; guests on `Invités` | `Jeux` in the shared folder `Partage`, and in `Lecture seule` and `Invités`, which they can only read |
| MinIO | 9000 | the player's keys, and a reader's | `Jeux` in the bucket `cartouche` |
| pyftpdlib | 2121, 2122 without MLSD | `joueur`, and `lecteur`, which only reads | `Jeux` at the root |
| OpenSSH | 2222 | `cartouche-test`, by password | `Jeux` in its home |
| The stand-in for Google | 9100 | `joueur@example.com`, through a made-up OAuth client, signed in once | `Jeux` in My Drive |

Each root also has `Lecture seule`, a folder the player's account can only read, with the small IPA.

Samba on a Mac needs two things a NAS does not. It makes a new folder under a temporary name, then renames it over an empty one of its name, as macOS has no `renameat2(RENAME_NOREPLACE)`, and macOS refuses that rename, as OpenBSD does ([Samba's bug 15801](https://bugzilla.samba.org/show_bug.cgi?id=15801)): `servers.sh` sets `vfs mkdir use tmp name = no`. And smbd, when it stops, stops every process of its process group: `servers.sh` starts it in a group of its own, not the runner's.

Samba, since 4.16, starts its RPC services (`samba-dcerpcd` and its `rpcd_*` workers) when a pipe is first opened, as the list of shared folders opens `srvsvc`, and stops them after a minute without use, so a NAS nobody used for a minute starts them again for the list. While they start, Samba 4.25 on the Mac once hung up the pipe (`STATUS_PIPE_DISCONNECTED`, in one run of six; Samba 4.19 on Linux never did in 46 tries): Cartouche asks for the list again, twice at most.

## Not here

What needs an iPhone: Bonjour, the keychain, folders picked in Files, and the views; the pairing's form, too, and the Mac's side of the bridge, which Cartouche Builder's own tests check (`builder/mac/Tests`). Nor the servers of NAS makers as they are configured out of the box; a NAS that behaves differently is worth a case here. Nor Google's own servers: the sheet iOS shows for the sign-in, Google's consent screen and its warning for an app Google has not verified, and the seven days Google keeps a sign-in of a project in testing, which only a player's iPhone and Google account show.
