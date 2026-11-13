Cartouche Installer 0.2.0 can install Cartouche with your own signing certificate, and fixes what its new tests found.

- **Your own certificate, as an option.** Under the Apple Account step, **I have a signing certificate (.p12)** installs Cartouche signed on the computer with your signing certificate and its provisioning profile, without an Apple ID, LocalDevVPN or a renewal each week. The certificate reaches Cartouche encrypted and stays in the iPhone's keychain. Before anything is installed, the installer checks the certificate, its password and the profile, names the app a profile was made for when it is not Cartouche, and says plainly when the profile lacks Increased Memory Limit, without which most games do not start. Games then start in Cartouche's place, and updates and a new certificate go through the installer. The Apple ID stays the default, unchanged. Not yet tried with a real certificate on a real iPhone. Thanks to javi11, who wrote it. How it works: [Using your signing certificate](https://github.com/clabeuhtegrite/Cartouche/blob/main/docs/imported-signing.md).
- **What the new tests found.** The Apple ID's password is no longer kept in the keychain against your choice, and a computer without a keychain no longer fails the sign-in; a pairing deleted or cut short is no longer taken for one kept; a saved Apple ID can be removed when the keychain lost its password; an install no longer leaves a copy of Cartouche in the temporary folder; the two-factor window and the certificates' window stay open when Apple refuses a code; and an answer to either of them is no longer lost when it comes quickly.
- Installing again still updates Cartouche and keeps its games and saves.

Downloads:

- **Mac**, Apple silicon and Intel, macOS 11 or later: `Cartouche-Installer-0.2.0-Mac.dmg`. The app is not notarized: the first time, open **System Settings › Privacy & Security** and click **Open Anyway**.
- **Windows** 10 or 11: `Cartouche-Installer-0.2.0-Windows.exe`. If SmartScreen stops it, **More info › Run anyway**. Windows needs **Apple Devices** from the Microsoft Store, or iTunes, to reach the iPhone.

Made from [iloader](https://github.com/nab138/iloader) by nab138 (MIT), with isideload and idevice. Not affiliated with iloader or Apple. How it works: [installer/README.md](https://github.com/clabeuhtegrite/Cartouche/blob/main/installer/README.md).
