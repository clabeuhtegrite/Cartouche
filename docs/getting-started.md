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
2. On the computer, download the **Cartouche Installer**: [for a Mac](https://clabeuhtegrite.github.io/Cartouche/download/#installer-mac), or [for a Windows PC](https://clabeuhtegrite.github.io/Cartouche/download/#installer-windows), which also needs **Apple Devices** from the Microsoft Store. Each link starts the download at once. The installer is not notarized: on a Mac, open **System Settings › Privacy & Security** and click **Open Anyway** next to it, once; on Windows, **More info › Run anyway** ([installer/README.md](../installer/README.md#download-and-first-open)).
3. Plug in the iPhone and unlock it; the first time, tap **Trust** on the iPhone and type its passcode. In the installer, sign in with your Apple account, then install. It puts Cartouche on the iPhone with its certificate, its memory capability and the pairing file.
4. On the iPhone, the first time only: in **Settings › General › VPN & Device Management**, trust your Apple account; if iOS asks for it, turn on **Developer Mode** in **Settings › Privacy & Security**, and restart.
5. Open Cartouche: its guide opens by itself. **Connect LocalDevVPN** connects it and brings you back to Cartouche. Then sign in with the Apple account you gave the installer, and type the code Apple sends: Cartouche takes its certificate, and from then on renews itself every week, without the computer.

## 2. Build your game on your Mac

The guide's **Send the steps to my Mac** sends the Mac [Cartouche Builder's page](https://clabeuhtegrite.github.io/Cartouche/#builder) of Cartouche's site, by AirDrop or Messages: its **Download Cartouche Builder** gives the disk image, and the steps below take it from there. Your games are built already, on your NAS for instance, or you have no Mac? **No thanks** skips this step, and the guide goes on to your games folder.

1. On a Mac with Apple silicon and macOS 26.6 or later, [download Cartouche Builder](https://clabeuhtegrite.github.io/Cartouche/download/#builder), open the disk image and drag **Cartouche Builder** onto **Applications**.
2. Open Cartouche Builder. The first time, macOS says it cannot check it, as it is not signed by Apple: in **System Settings › Privacy & Security**, click **Open Anyway** beside Cartouche Builder, once.
3. Its setup assistant sets up the Mac with you, a step at a time. Nothing is chosen for you, and each choice can be changed later in the settings ([builder/README.md](../builder/README.md#install)):
   - **This Mac's tools:** **Get everything ready** installs what nxnative builds with. Xcode 27.2, free from Apple, comes from the App Store, which the app opens for you, or from [Apple's developer downloads](https://developer.apple.com/download/all/) while the App Store offers another version; Homebrew asks for your Mac's password; the rest installs in the background, while you go on to the next steps.
   - **Your dumps** and **Games folder:** the folder of your dumps, one folder per game with its packages (`.nsp`, `.xci`, `.nsz`, `.xcz`, a Switch 2 game's `.nup`) or its dump, which the builder only reads; then where your games' IPAs go, on the Mac or on your NAS; and under **Keys**, `prod.keys`, your console's keys, for packages.
   - **iPhone:** turn on **Share with Cartouche on the iPhone**, for Cartouche to install your games from the Mac.
4. In **Library**, open your game and choose **Build**. A large game's first build takes hours; the next ones reuse its build folder. A game you follow is built again when nxnative improves it: **Rebuild what is due** builds them, and with **Build what is due every night**, in the settings, the Mac does it at night. Cartouche then offers you the update.

## 3. Choose your games folder in Cartouche

In Cartouche, the guide's **Choose the games folder** opens the storage page. Your iPhone reads the games folder where it is, on your network:

- **On your Mac:** choose **Add your Mac (Cartouche Builder)**, then your Mac under **Macs nearby**; the first time, allow Cartouche to find devices on your local network. Both screens show six digits: when they are the same, click **Allow** on the Mac. Cartouche then installs your games from the Mac and keeps your saves there, encrypted on the way. The iPhone finds the Mac on your Wi-Fi, or through your VPN at the address it last reached it at.
- **On your NAS:** add it with its address, your user name and password, then choose the games folder. An SFTP or FTP server, an S3 bucket of yours or a folder in Files will do too, and so does your Mac's own File Sharing (SMB).

Cartouche lists your games from there and offers their updates.

No games folder? Put the IPA in Files on the iPhone, by AirDrop for instance, and choose **Import an IPA instead**.

## 4. Install your game and play

Your game shows in the guide's last step and in your library: **Install** installs it from your games folder, then its sheet opens with **Play**. Your first game is on your iPhone; the next ones go the same way, built on the Mac, then installed.

## Afterwards

- **Leave LocalDevVPN on** when you can: Cartouche renews its seven-day signature through it, from the System page or every night with the Shortcuts automation that page explains.
- **Your saves:** with a saves folder chosen on the storage page, Cartouche keeps each game's saves in step with it: they come when you install the game and before it starts, as after you install Cartouche again or play on another iPhone, and go after each game.
- **Updates:** Cartouche offers its new versions itself, and the update of a game when your games folder holds a newer build of it. Cartouche Builder updates itself, when it builds nothing.
- **The guide:** the × on its card takes it off the home; **System › Your first game** opens it again whenever you want.
- **The certificate no longer works:** the home says so; sign in again. **The pairing file is missing:** the installer puts it in Cartouche again, or installs Cartouche again over this copy, which keeps your games and their saves.

Cartouche ships no games, no keys and no firmware, and never downloads them; Cartouche Builder builds yours from your own files, on your Mac, into your own games folder ([LEGAL.md](../LEGAL.md)).
