# Getting started

*Français : [getting-started.fr.md](getting-started.fr.md)*

From nothing to your first game on your iPhone, in four steps. Cartouche never downloads a game: you build each of yours on your Mac, from your own copy, dumped from your own console. In Cartouche, the guide **Your first game** takes you through the same steps, and ticks each one by itself once it is done.

## What you need

- **An iPhone** with iOS 26 or later: an iPhone 15 Pro or newer, or an iPad with an M1 or newer. The bigger games need a 12 GB iPhone.
- **A Mac or a Windows PC, once,** with a cable for the iPhone, to install Cartouche.
- **A Mac with Apple silicon** (M1 or later) on macOS 26.6 or later, to build your games, with Xcode 27.2, free from Apple, and room for the builds. Only a Mac can build them: without one, Cartouche has nothing to play, since nobody may send you their games.
- **An Apple account** (Apple ID): a free one is enough.
- **Your games,** copied from your own console, and for a Switch game your console's keys (`prod.keys`).

## 1. Install Cartouche on your iPhone

1. On the iPhone, install [LocalDevVPN](https://apps.apple.com/app/localdevvpn/id6755608044) from the App Store. Cartouche signs in and renews itself through it; its traffic never leaves the iPhone.
2. On the computer, download the **Cartouche Installer** from its latest `installer-v…` [release](https://github.com/clabeuhtegrite/Cartouche/releases): `Cartouche-Installer-<version>-Mac.dmg` for a Mac, `Cartouche-Installer-<version>-Windows.exe` for a Windows PC, which also needs **Apple Devices** from the Microsoft Store. The installer is not notarized: on a Mac, open **System Settings › Privacy & Security** and click **Open Anyway** next to it, once; on Windows, **More info › Run anyway** ([installer/README.md](../installer/README.md#download-and-first-open)).
3. Plug in the iPhone and unlock it; the first time, tap **Trust** on the iPhone and type its passcode. In the installer, sign in with your Apple account, then install. It puts Cartouche on the iPhone with its certificate, its memory capability and the pairing file.
4. On the iPhone, the first time only: in **Settings › General › VPN & Device Management**, trust your Apple account; if iOS asks for it, turn on **Developer Mode** in **Settings › Privacy & Security**, and restart.
5. Open Cartouche: its guide opens by itself. **Connect LocalDevVPN** connects it and brings you back to Cartouche. Then sign in with the Apple account you gave the installer, and type the code Apple sends: Cartouche takes its certificate, and from then on renews itself every week, without the computer.

## 2. Build your game on your Mac

The guide's **Send the steps to my Mac** sends this page to the Mac, by AirDrop or Messages.

1. Install **Xcode 27.2**, free from Apple: from the App Store when it offers 27.2, otherwise from [Apple's developer downloads](https://developer.apple.com/download/all/) (search for Xcode 27.2, sign in with your Apple account, then move Xcode to Applications). Open Xcode once, agree to its licence and tick **iOS** among the platforms it offers.
2. Open **Terminal** (in Applications › Utilities), paste this command and press Return:

   ```
   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/clabeuhtegrite/Cartouche/main/builder/install.sh)"
   ```

   It installs [Homebrew](https://brew.sh) if the Mac has none, then Python with Tk, `xcodegen`, `zstd` and `glslang`, readies Xcode's iOS platform and Metal toolchain, puts **Cartouche Builder** in the Applications folder of your home folder, downloads nxnative, and opens Cartouche Builder. Homebrew asks for your Mac's password. Should Xcode be missing or never have been opened, the command says so: run it again afterwards, and it picks up from there. The same command updates Cartouche Builder later ([builder/install.sh](../builder/install.sh)).
3. In Cartouche Builder, choose your folders ([builder/README.md](../builder/README.md#start)):
   - **Game sources:** one folder per game, with its packages (`.nsp`, `.xci`, `.nsz`, `.xcz`, a Switch 2 game's `.nup`) or its dump. The builder only reads them.
   - **Games folder:** where your games' IPAs go, the folder your iPhone reads, such as a folder named Games in your home folder, or one on your NAS.
   - **prod.keys:** your console's keys, for packages.

   **Mac tools…** checks the Mac, and opens the command that installs anything still missing.
4. Select your game in the list and choose **Build the selection**. A large game's first build takes hours; the next ones reuse its build folder. With **Build what is due every night at**, Cartouche Builder builds your games again when nxnative improves them, and Cartouche offers you the update.

## 3. Choose your games folder in Cartouche

Your iPhone reads the games folder where it is, on your network:

- **On your Mac:** in **System Settings › General › Sharing**, turn on **File Sharing**, then click ⓘ next to it, add your games folder under **Shared Folders**, and in **Options…**, keep **Share files and folders using SMB** on and tick your account under **Windows File Sharing**, for the iPhone to sign in with your Mac's user name and password. The Mac shows its address there, such as `smb://MacBook-Air.local`.
- **On your NAS:** a shared folder of yours, with your account.

In Cartouche, the guide's **Choose the games folder** opens the storage page: add your Mac or your NAS with its address, your user name and password, then choose the games folder. Cartouche lists your games from there and offers their updates. An SFTP or FTP server, an S3 bucket of yours or a folder in Files will do too.

No games folder? Put the IPA in Files on the iPhone, by AirDrop for instance, and choose **Import an IPA instead**.

## 4. Install your game and play

Your game shows in the guide's last step and in your library: **Install** installs it from your games folder, then its sheet opens with **Play**. Your first game is on your iPhone; the next ones go the same way, built on the Mac, then installed.

## Afterwards

- **Leave LocalDevVPN on** when you can: Cartouche renews its seven-day signature through it, from the System page or every night with the Shortcuts automation that page explains.
- **Updates:** Cartouche offers its new versions itself, and the update of a game when your games folder holds a newer build of it.
- **The certificate no longer works:** the home says so; sign in again. **The pairing file is missing:** the installer puts it in Cartouche again, or installs Cartouche again over this copy, which keeps your games and their saves.

Cartouche ships no games, no keys and no firmware, and never downloads them; Cartouche Builder builds yours from your own files, on your Mac, into your own games folder ([LEGAL.md](../LEGAL.md)).
