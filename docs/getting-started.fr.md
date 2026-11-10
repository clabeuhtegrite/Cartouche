# Premiers pas

*English: [getting-started.md](getting-started.md)*

De rien à votre premier jeu sur votre iPhone, en quatre étapes. Cartouche ne télécharge jamais de jeu : vous construisez chacun des vôtres sur votre Mac, à partir de votre propre copie, extraite de votre propre console. Dans Cartouche, le guide **Votre premier jeu** reprend ces étapes, et coche chacune toute seule une fois faite.

## Ce qu’il vous faut

- **Un iPhone** sous iOS 26 ou ultérieur : un iPhone 15 Pro ou plus récent, ou un iPad avec une puce M1 ou plus récente. Les plus gros jeux demandent un iPhone de 12 Go.
- **Un Mac ou un PC Windows, une seule fois,** avec un câble pour l’iPhone, pour installer Cartouche.
- **Un Mac à puce Apple** (M1 ou plus récent) sous macOS 26.6 ou ultérieur, pour construire vos jeux, avec Xcode 27.2, gratuit chez Apple, et de la place pour les constructions. Seul un Mac peut les construire : sans Mac, Cartouche n’a rien à lancer, puisque personne n’a le droit de vous envoyer ses jeux.
- **Un compte Apple** (identifiant Apple) : un compte gratuit suffit.
- **Vos jeux,** copiés depuis votre propre console, et pour un jeu Switch les clés de votre console (`prod.keys`).

## 1. Installez Cartouche sur votre iPhone

1. Sur l’iPhone, installez [LocalDevVPN](https://apps.apple.com/app/localdevvpn/id6755608044) depuis l’App Store. Cartouche se connecte et se renouvelle par lui ; son trafic ne sort jamais de l’iPhone.
2. Sur l’ordinateur, téléchargez l’**Installeur Cartouche** depuis sa dernière [version](https://github.com/clabeuhtegrite/Cartouche/releases) `installer-v…` : `Cartouche-Installer-<version>-Mac.dmg` pour un Mac, `Cartouche-Installer-<version>-Windows.exe` pour un PC Windows, qui demande aussi **Appareils Apple** depuis le Microsoft Store. L’installeur n’est pas notarié : sur un Mac, ouvrez **Réglages Système › Confidentialité et sécurité** et cliquez sur **Ouvrir quand même** à côté de lui, une fois ; sous Windows, **Informations complémentaires › Exécuter quand même** ([installer/README.md](../installer/README.md#download-and-first-open)).
3. Branchez l’iPhone et déverrouillez-le ; la première fois, touchez **Se fier** sur l’iPhone et saisissez son code. Dans l’installeur, connectez-vous avec votre compte Apple, puis installez. Il met Cartouche sur l’iPhone avec son certificat, sa capacité de mémoire et le fichier de jumelage.
4. Sur l’iPhone, la première fois seulement : dans **Réglages › Général › VPN et gestion de l’appareil**, faites confiance à votre compte Apple ; si iOS le demande, activez le **mode développeur** dans **Réglages › Confidentialité et sécurité**, puis redémarrez.
5. Ouvrez Cartouche : son guide s’ouvre tout seul. **Connecter LocalDevVPN** le connecte et vous ramène dans Cartouche. Connectez-vous ensuite avec le compte Apple donné à l’installeur, et saisissez le code qu’Apple envoie : Cartouche prend son certificat, et se renouvelle dès lors chaque semaine, sans l’ordinateur.

## 2. Construisez votre jeu sur votre Mac

**Envoyer les étapes à mon Mac**, dans le guide, envoie cette page au Mac, par AirDrop ou Messages.

1. Installez **Xcode 27.2**, gratuit chez Apple : depuis l’App Store s’il propose la 27.2, sinon depuis les [téléchargements pour développeurs d’Apple](https://developer.apple.com/download/all/) (cherchez Xcode 27.2, connectez-vous avec votre compte Apple, puis placez Xcode dans Applications). Ouvrez Xcode une fois, acceptez sa licence et cochez **iOS** parmi les plateformes qu’il propose.
2. Ouvrez **Terminal** (dans Applications › Utilitaires), collez cette commande et appuyez sur Entrée :

   ```
   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/clabeuhtegrite/Cartouche/main/builder/install.sh)"
   ```

   Elle installe [Homebrew](https://brew.sh) si le Mac ne l’a pas, puis Python avec Tk, `xcodegen`, `zstd` et `glslang`, prépare la plateforme iOS et la Metal toolchain de Xcode, met **Cartouche Builder** dans le dossier Applications de votre dossier personnel, télécharge nxnative, et ouvre Cartouche Builder. Homebrew demande le mot de passe de votre Mac. Si Xcode manque, ou n’a jamais été ouvert, la commande le dit : relancez-la ensuite, elle reprend là. La même commande met Cartouche Builder à jour plus tard ([builder/install.sh](../builder/install.sh)).
3. Dans Cartouche Builder, choisissez vos dossiers ([builder/README.md](../builder/README.md#start)) :
   - **Sources des jeux :** un dossier par jeu, avec ses paquets (`.nsp`, `.xci`, `.nsz`, `.xcz`, le `.nup` d’un jeu Switch 2) ou son extraction. Le compilateur ne fait que les lire.
   - **Dossier des jeux :** là où vont les IPA de vos jeux, le dossier que lit votre iPhone, comme un dossier nommé Jeux dans votre dossier personnel, ou un dossier de votre NAS.
   - **prod.keys :** les clés de votre console, pour les paquets.

   **Outils du Mac…** vérifie le Mac, et ouvre la commande qui installe ce qui manque encore.
4. Sélectionnez votre jeu dans la liste et choisissez **Construire la sélection**. La première construction d’un gros jeu prend des heures ; les suivantes réutilisent son dossier de construction. Avec **Construire ce qui est dû chaque nuit à**, Cartouche Builder reconstruit vos jeux quand nxnative les améliore, et Cartouche vous propose la mise à jour.

## 3. Choisissez votre dossier des jeux dans Cartouche

Votre iPhone lit le dossier des jeux là où il est, sur votre réseau :

- **Sur votre Mac :** dans **Réglages Système › Général › Partage**, activez **Partage de fichiers**, puis cliquez sur ⓘ à côté, ajoutez votre dossier des jeux sous **Dossiers partagés**, et dans **Options…**, laissez **Partager des fichiers et dossiers via SMB** activé et cochez votre compte sous **Partage de fichiers Windows**, pour que l’iPhone se connecte avec le nom d’utilisateur et le mot de passe de votre Mac. Le Mac y affiche son adresse, comme `smb://MacBook-Air.local`.
- **Sur votre NAS :** un dossier partagé à vous, avec votre compte.

Dans Cartouche, **Choisir le dossier des jeux**, dans le guide, ouvre la page du stockage : ajoutez votre Mac ou votre NAS avec son adresse, votre nom d’utilisateur et votre mot de passe, puis choisissez le dossier des jeux. Cartouche y liste vos jeux et propose leurs mises à jour. Un serveur SFTP ou FTP, un bucket S3 à vous ou un dossier de Fichiers conviennent aussi.

Pas de dossier des jeux ? Mettez l’IPA dans Fichiers sur l’iPhone, par AirDrop par exemple, et choisissez **Importer plutôt une IPA**.

## 4. Installez votre jeu et jouez

Votre jeu apparaît dans la dernière étape du guide et dans votre bibliothèque : **Installer** l’installe depuis votre dossier des jeux, puis sa fiche s’ouvre avec **Jouer**. Votre premier jeu est sur votre iPhone ; les suivants prennent le même chemin, construits sur le Mac, puis installés.

## Ensuite

- **Laissez LocalDevVPN allumé** quand vous le pouvez : Cartouche renouvelle sa signature de sept jours par lui, depuis la page Système ou chaque nuit avec l’automatisation Raccourcis que cette page explique.
- **Mises à jour :** Cartouche propose lui-même ses nouvelles versions, et la mise à jour d’un jeu quand votre dossier des jeux en a une construction plus récente.
- **Le certificat ne marche plus :** l’accueil le dit ; reconnectez-vous. **Le fichier de jumelage manque :** l’installeur le remet dans Cartouche, ou réinstalle Cartouche par-dessus cette copie, ce qui garde vos jeux et leurs sauvegardes.

Cartouche ne fournit ni jeux, ni clés, ni firmware, et ne les télécharge jamais ; Cartouche Builder construit les vôtres à partir de vos propres fichiers, sur votre Mac, dans votre propre dossier des jeux ([LEGAL.md](../LEGAL.md)).
