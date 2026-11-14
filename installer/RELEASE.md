Cartouche Installer 0.2.1 makes sure your two-factor code, and the certificates you choose to revoke, always reach it.

- **Sign-in.** The two-factor code and the choice of certificates to revoke can no longer be lost on the way from the window, which made the sign-in fail after two minutes.
- **Your own certificate.** The installer puts the latest Cartouche on the iPhone, and Cartouche 0.12.1 no longer closes at its first launch when it is signed with your own certificate. Thanks to javi11, who found it on a real iPhone and fixed it.
- Installing again still updates Cartouche and keeps its games and saves.

Downloads:

- **Mac**, Apple silicon and Intel, macOS 11 or later: `Cartouche-Installer-0.2.1-Mac.dmg`. The app is not notarized: the first time, open **System Settings › Privacy & Security** and click **Open Anyway**.
- **Windows** 10 or 11: `Cartouche-Installer-0.2.1-Windows.exe`. If SmartScreen stops it, **More info › Run anyway**. Windows needs **Apple Devices** from the Microsoft Store, or iTunes, to reach the iPhone.

Made from [iloader](https://github.com/nab138/iloader) by nab138 (MIT), with isideload and idevice. Not affiliated with iloader or Apple. How it works: [installer/README.md](https://github.com/clabeuhtegrite/Cartouche/blob/main/installer/README.md).
