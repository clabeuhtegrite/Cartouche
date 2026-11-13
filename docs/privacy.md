# Privacy

What Cartouche sends, where, and what it never sends.

## Your games, saves and accounts

Cartouche downloads no game, and sends none of your games' or saves' files anywhere but the storage you set up yourself, with your own account: your Mac with Cartouche Builder, a shared folder, an FTP or SFTP server, an S3 bucket, your Google Drive or a folder in Files. That account's password, or the sign-in Google gives, stays in the iPhone's keychain. So do your storage's settings, its servers and the folders you chose, without their passwords, so that Cartouche finds them if you install it again; removing a server in Cartouche removes it there too.

Your Mac is reached on your own network, or through your own VPN, and only once you clicked **Allow** on it for this iPhone, when both screens showed the same six digits. The key they then share stays in the iPhone's keychain and in Cartouche Builder's folder on the Mac, readable by your account only; it never crosses the network, and every exchange after is encrypted with it. Cartouche sees only two folders of the Mac, the games folder and the saves folder you chose in Cartouche Builder; removing the iPhone from Cartouche Builder's list ends its access.

Your Google Drive is reached with an OAuth client of your own, made in your own Google Cloud project, and your own Google account: Cartouche has no Google key, and neither the project nor its servers ever see your sign-in or your files. You sign in on Google's own page, in the sheet iOS shows for it; Google asks you to let your client see, edit and delete your Drive's files: Cartouche lists My Drive's folders for you to choose yours, then reads and writes only in those. The sign-in Google gives, a refresh token, stays in the iPhone's keychain and goes only to Google; removing the Drive in Cartouche removes it from the iPhone, and your Google account's list of the apps you allowed ends it at Google too.

Your Apple ID and its password stay in the keychain Cartouche shares with its built-in SideStore, which gives them only to Apple, to sign Cartouche and your games.

Should you install Cartouche with your own signing certificate instead ([imported-signing.md](imported-signing.md)), the Cartouche Installer signs it on your computer, without contacting Apple; it hands the certificate, its password and its profile to Cartouche encrypted, with a key of that install alone, and Cartouche keeps them in this iPhone's keychain only, then deletes the file the installer left.

## Game measurements

Cartouche sends what your games measured as they ran, so that they can be made to run better on iPhones. It does so unless you turn it off: **System › Game measurements › Send game measurements**. Off, Cartouche sends nothing more and drops the reports it had not sent yet; on again, it reports only the sessions that come after.

### What is sent

- **After each game session,** what nxnative measured and wrote in the game's log, as numbers: the frame rate and frame times, the frames that came late, the stutters and what they waited for, the shader preparation, CPU and GPU load, power, heat, Low Power Mode, memory, the upscaler, audio underruns and how the session ended: for a crash, its signal and where in the game's code, as an offset. For a game that ran behind the console, also what its own process measured of its memory, the sizes its screen took, and whether you quit it. With them, the game's title ID and version, the nxnative commit it was built from, its nxnative settings, and how long the session lasted.
- **Cartouche's own events:** each start, with how many games you have, whether the setup is done, which kind of storage you use and whether Cartouche signs with an Apple ID or a certificate of yours; its updates; the renewals of its signature; the games installed, with their version; the games whose info you change, with which of it you changed, never what you wrote or chose; each Apple ID sign-in that goes through, with how long it took; each signing certificate you import, with whether it went in or why not, never the certificate, its password, its team or its profile; the Files picker of each import, with how it closed, where you opened it, how long it took to show and stayed open, and how long Cartouche took to answer meanwhile; and the errors it shows, as what it was doing, the error's codes and the cause Cartouche tells from them, the step it stopped at, how far and how long it got, and, for the sign-in, the renewal and the update the built-in SideStore runs, the names and numbers SideStore leaves of its error (its case, Apple's code, a server's HTTP status, what kind of server it could not reach, whether Apple asked for a code, how many certificates and teams the account has, whether the VPN was on), never its message, the Apple ID, a team, a certificate, a device, a path or an address.
- **With each report:** the iPhone's model, such as `iPhone19,4`, its iOS version, Cartouche's version and language, the memory limit iOS sets for Cartouche, whether it has Increased Memory Limit, and a random number for this copy of Cartouche, which it replaces every 13 months.

The full list is in [telemetry/README.md](../telemetry/README.md#reports). **System › Game measurements › Last report** shows the last report as it left the iPhone.

### What is never sent

- A line of a game's log, which can hold paths and keys; a file, a game or a save.
- Your Apple ID, your name, the iPhone's name, its serial number or any identifier of Apple's, such as the advertising identifier.
- Anything of your storage: its address, folders, account or password.
- Your location, contacts, photos, or anything of another app.

### Where it goes, and for how long

The reports go to the project's own server, a Cloudflare Worker, which keeps them in a database in the European Union, Cloudflare's EU jurisdiction. Cloudflare, which runs it, sees the address a report comes from, as any website's host does; the server does not keep it, nor the time: only the day it received the report. It leaves out anything the app is not meant to send.

Reports are deleted after 25 months. They are read by the project, to fix and improve the games and Cartouche, and published only as figures of at least three iPhones, such as in the game sheets of [`catalog/`](../catalog/README.md), each week; never one report, and never sold or shared. The project reads them on a dashboard of its own, another Worker beside the server, which only the project's accounts can open, through Cloudflare Access ([telemetry/README.md](../telemetry/README.md#dashboard)), and its sessions in an export of the same reports that a workflow of this repository encrypts for the session that asks for it, which alone can open it ([telemetry/README.md](../telemetry/README.md#export)).

### Erasing it

**System › Game measurements › Erase what this iPhone sent** has the server delete every report of this copy of Cartouche, which then takes a new random number.

## Cartouche Builder

Cartouche Builder, on the Mac, sends how it is used and how its builds go, so that building games for the iPhone can be made easier and more reliable. It does so unless you turn it off: **Settings › General › Send usage measures**. Off, it sends nothing more and drops the reports it had not sent yet.

- **What is sent:** each start, with how many games it follows and how many are due, whether the Mac's tools are ready, which of its settings are on, whether the bridge is on and how many iPhones are paired, and the Xcode and nxnative it builds with; each tool it installs; each game built or failed, by its title ID, with why it was due, how long it took, the kind of files it was built from, the step that failed and the IPA's size; each batch, with how many games it built and how long it took; the room freed on its Storage page; each IPA made whole with its game data, by its title ID, with how long it took, its size and the nxnative it was built with; each pairing asked, and whether you allowed it; its updates; and the errors it shows, as what it was doing and the error's codes, or, for its engine's, the class of the exception, the module and function that met it, its errno and exit status, never its message. With each report: the Mac's model, such as `Mac16,12`, its macOS version, its memory and cores, Cartouche Builder's version and language, and a random number for this copy of Cartouche Builder, which it replaces every 13 months.
- **What is never sent:** a path, a file's or a folder's name, a game's name, files or saves; a line of a build's log; `prod.keys` or any key; the Mac's name, your name, your Apple account, the names of your iPhones; the address or account of a NAS.

The full list is in [telemetry/README.md](../telemetry/README.md#cartouche-builder). The reports go to the same server as Cartouche's, are kept as long and read the same way. **Erase what this Mac sent**, beside the switch, has the server delete every report of this copy of Cartouche Builder, which then takes a new random number.

## Reporting a problem

**System › Report a problem** shows all a report holds before anything leaves the iPhone, and sends nothing until you choose how: share it, copy it, open GitHub's bug report form with it, or **Send to Cartouche**. Cartouche takes out of it, and out of what you write, the names and addresses of your servers and folders, your user names, your Apple ID and your team, and never puts a password in it.

It holds what you write; Cartouche's and iOS's versions and the iPhone's model, language, memory, free space and how far the setup is; Cartouche's last steps; the reports of its last errors of the week; and the iPhone's memory limit, for the catalog's list of iPhones.

**Send to Cartouche** gives it to the project's server, which files it as an issue of the project's private repository on GitHub, read only by the project, and kept there until the project deletes it. GitHub stores it in the United States. The server keeps it only until GitHub has it, then only the day it came, until the day after; as with game measurements, it never keeps the address it came from. Through GitHub's form, a report is public, under your GitHub account.

## Games Cartouche does not know

For a game of yours that Cartouche's catalog does not know, such as one built with another version of nxnative, Cartouche asks the project's server, the one game measurements go to, for its cover, its artwork and its genre on IGDB. It sends the game's name, as your copy gives it or as you renamed it, and whether it is a Switch or a Switch 2 game when its title ID or you say so: nothing else, not even its title ID, nor the random number of game measurements, and whether those are on or not. The server asks IGDB, and keeps IGDB's answer for that name 30 days, to give it to whoever asks for the same name; it never keeps who asked, nor the address the question came from. Cartouche keeps the answer on the iPhone, and asks again a month later.

The name, platform, genre and cover you give a game yourself, in its **Details › Edit the game's info**, stay on the iPhone, with the picture you chose: only the name and the platform of a game the catalog does not know go to the server, as above, for the game to be looked up under them.

## Other connections

Cartouche also reads the list of its own versions on GitHub, to offer its updates, and loads the games' covers from IGDB's image server. Both see the iPhone's address, as any website does, and nothing else of you. With your Google Drive, Cartouche reaches Google's sign-in page, its token server and the Drive API, and nothing else of Google's. Cartouche Builder reads its own versions on GitHub every six hours, the list of covers from this repository and the covers from IGDB's image server, and keeps its copy of nxnative up to date from GitHub; installing the Mac's tools, it reaches Homebrew and Apple's servers as their installers do.

The code of all this is in this repository: the app's side in [`CartoucheTelemetry.swift`](../launcher/Sources/CartoucheTelemetry.swift), Cartouche Builder's in [`BuilderTelemetry.swift`](../builder/mac/Sources/BuilderKit/BuilderTelemetry.swift), the bridge in [`CartoucheBridge.swift`](../launcher/Sources/CartoucheBridge.swift), the server in [`telemetry/`](../telemetry/README.md).
