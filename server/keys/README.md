# Manifest public keys

One file per channel, `<channel>.pub`, holding the base64 Ed25519 public key that the app pins. None exists yet: the first key is made with `cartouche-server keygen` when the first channel is published, and its private half is stored only as a CI secret.
