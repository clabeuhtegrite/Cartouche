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

1. Sur un Mac à puce Apple sous macOS 26.6 ou ultérieur, téléchargez `Cartouche-Builder-<version>.dmg` depuis la dernière [version `builder-v<version>`](https://github.com/clabeuhtegrite/Cartouche/releases), ouvrez-le et glissez **Cartouche Builder** sur **Applications**.
2. Ouvrez Cartouche Builder. La première fois, macOS dit qu’il ne peut pas le vérifier, car il n’est pas signé par Apple : dans **Réglages Système › Confidentialité et sécurité**, cliquez sur **Ouvrir quand même** à côté de Cartouche Builder, une fois.
3. Cartouche Builder prépare le Mac avec vous, une page après l’autre ([builder/README.md](../builder/README.md#install)) :
   - **Les outils du Mac :** **Tout préparer** installe ce avec quoi nxnative construit. Xcode 27.2, gratuit chez Apple, vient de l’App Store, que l’app vous ouvre, ou des [téléchargements pour développeurs d’Apple](https://developer.apple.com/download/all/) tant que l’App Store propose une autre version ; Homebrew demande le mot de passe de votre Mac ; le reste s’installe en arrière-plan.
   - **Vos jeux :** les **Sources des jeux**, un dossier par jeu avec ses paquets (`.nsp`, `.xci`, `.nsz`, `.xcz`, le `.nup` d’un jeu Switch 2) ou son dump, que le builder ne fait que lire ; le **Dossier des jeux**, où vont les IPA de vos jeux, sur le Mac ou sur votre NAS ; et `prod.keys`, les clés de votre console, pour les paquets.
   - **Cartouche sur l’iPhone :** laissez **Partager avec Cartouche sur l’iPhone** activé, pour que Cartouche installe vos jeux depuis le Mac.
4. Dans **Bibliothèque**, ouvrez votre jeu et choisissez **Construire**. La première construction d’un gros jeu prend des heures ; les suivantes réutilisent son dossier de construction. Un jeu que vous suivez est reconstruit quand nxnative l’améliore : **Reconstruire ce qui est dû** les construit, et avec **Construire ce qui est dû chaque nuit**, dans les réglages, le Mac s’en charge la nuit. Cartouche vous propose ensuite la mise à jour.

## 3. Choisissez votre dossier des jeux dans Cartouche

Dans Cartouche, **Choisir le dossier des jeux**, dans le guide, ouvre la page du stockage. Votre iPhone lit le dossier des jeux là où il est, sur votre réseau :

- **Sur votre Mac :** choisissez **Ajouter votre Mac (Cartouche Builder)**, puis votre Mac sous **Macs à proximité** ; la première fois, autorisez Cartouche à trouver les appareils de votre réseau local. Les deux écrans affichent six chiffres : s’ils sont les mêmes, cliquez sur **Autoriser** sur le Mac. Cartouche installe alors vos jeux depuis le Mac et y garde vos sauvegardes, chiffrées en chemin. L’iPhone trouve le Mac sur votre Wi-Fi, ou par votre VPN à l’adresse où il l’a joint la dernière fois.
- **Sur votre NAS :** ajoutez-le avec son adresse, votre nom d’utilisateur et votre mot de passe, puis choisissez le dossier des jeux. Un serveur SFTP ou FTP, un bucket S3 à vous ou un dossier de Fichiers conviennent aussi, tout comme le Partage de fichiers (SMB) de votre Mac.

Cartouche y liste vos jeux et propose leurs mises à jour.

Pas de dossier des jeux ? Mettez l’IPA dans Fichiers sur l’iPhone, par AirDrop par exemple, et choisissez **Importer plutôt une IPA**.

## 4. Installez votre jeu et jouez

Votre jeu apparaît dans la dernière étape du guide et dans votre bibliothèque : **Installer** l’installe depuis votre dossier des jeux, puis sa fiche s’ouvre avec **Jouer**. Votre premier jeu est sur votre iPhone ; les suivants prennent le même chemin, construits sur le Mac, puis installés.

## Ensuite

- **Laissez LocalDevVPN allumé** quand vous le pouvez : Cartouche renouvelle sa signature de sept jours par lui, depuis la page Système ou chaque nuit avec l’automatisation Raccourcis que cette page explique.
- **Vos sauvegardes :** avec un dossier des sauvegardes choisi sur la page du stockage, Cartouche y synchronise les sauvegardes de chaque jeu : elles arrivent quand vous installez le jeu et avant chaque lancement, comme après une réinstallation de Cartouche ou une partie sur un autre iPhone, et y repartent après chaque partie.
- **Mises à jour :** Cartouche propose lui-même ses nouvelles versions, et la mise à jour d’un jeu quand votre dossier des jeux en a une construction plus récente. Cartouche Builder se met à jour tout seul, quand il ne construit rien.
- **Le certificat ne marche plus :** l’accueil le dit ; reconnectez-vous. **Le fichier de jumelage manque :** l’installeur le remet dans Cartouche, ou réinstalle Cartouche par-dessus cette copie, ce qui garde vos jeux et leurs sauvegardes.

Cartouche ne fournit ni jeux, ni clés, ni firmware, et ne les télécharge jamais ; Cartouche Builder construit les vôtres à partir de vos propres fichiers, sur votre Mac, dans votre propre dossier des jeux ([LEGAL.md](../LEGAL.md)).
