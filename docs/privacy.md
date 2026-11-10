# Privacy

What Cartouche sends, where, and what it never sends.

## Your games, saves and accounts

Cartouche downloads no game, and sends none of your games' or saves' files anywhere but the storage you set up yourself, with your own account: a shared folder, an FTP or SFTP server, an S3 bucket or a folder in Files. That account's password stays in the iPhone's keychain.

Your Apple ID and its password stay in the keychain Cartouche shares with its built-in SideStore, which gives them only to Apple, to sign Cartouche and your games.

## Game measurements

Cartouche sends what your games measured as they ran, so that they can be made to run better on iPhones. It does so unless you turn it off: **System › Game measurements › Send game measurements**. Off, Cartouche sends nothing more and drops the reports it had not sent yet; on again, it reports only the sessions that come after.

### What is sent

- **After each game session,** what nxnative measured and wrote in the game's log, as numbers: the frame rate and frame times, the frames that came late, the stutters and what they waited for, the shader preparation, CPU and GPU load, power, heat, Low Power Mode, memory, the upscaler, audio underruns and how the session ended: for a crash, its signal and where in the game's code, as an offset. With them, the game's title ID and version, the nxnative commit it was built from, its nxnative settings, and how long the session lasted.
- **Cartouche's own events:** each start, with how many games you have, whether the setup is done and which kind of storage you use; its updates; the renewals of its signature; the games installed, with their version; and the errors it shows, as what it was doing and the error's codes, never its message.
- **With each report:** the iPhone's model, such as `iPhone19,4`, its iOS version, Cartouche's version and language, the memory limit iOS sets for Cartouche, whether it has Increased Memory Limit, and a random number for this copy of Cartouche, which it replaces every 13 months.

The full list is in [telemetry/README.md](../telemetry/README.md#reports). **System › Game measurements › Last report** shows the last report as it left the iPhone.

### What is never sent

- A line of a game's log, which can hold paths and keys; a file, a game or a save.
- Your Apple ID, your name, the iPhone's name, its serial number or any identifier of Apple's, such as the advertising identifier.
- Anything of your storage: its address, folders, account or password.
- Your location, contacts, photos, or anything of another app.

### Where it goes, and for how long

The reports go to the project's own server, a Cloudflare Worker, which keeps them in a database in the European Union, Cloudflare's EU jurisdiction. Cloudflare, which runs it, sees the address a report comes from, as any website's host does; the server does not keep it, nor the time: only the day it received the report. It leaves out anything the app is not meant to send.

Reports are deleted after 25 months. They are read by the project, to fix and improve the games and Cartouche, and published only as figures of several iPhones, such as in the game sheets of [`catalog/`](../catalog/README.md); never one report, and never sold or shared.

### Erasing it

**System › Game measurements › Erase what this iPhone sent** has the server delete every report of this copy of Cartouche, which then takes a new random number.

## Other connections

Cartouche also reads the list of its own versions on GitHub, to offer its updates, and loads the games' covers from IGDB's image server. Both see the iPhone's address, as any website does, and nothing else of you.

The code of all this is in this repository: the app's side in [`CartoucheTelemetry.swift`](../launcher/Sources/CartoucheTelemetry.swift), the server in [`telemetry/`](../telemetry/README.md).
