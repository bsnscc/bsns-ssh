# Config-bundle cross-platform wire contract

The encrypted **envelope** (`bsns-config-aesgcm-v1`: PBKDF2-SHA256/210k → AES-256-GCM,
`nonce ‖ ct ‖ tag`) is byte-identical on iOS and Android — a bundle sealed on one
platform decrypts on the other. The **JSON inside** the envelope, however, was
historically written differently by each app. As of the cross-platform import/sync
fix, each app keeps writing its own native shape but *decodes the other's*
losslessly, and both use one shared sync filename.

This file is the golden reference for that contract. The two fixtures below are
each meant to round-trip through the *other* platform's importer.

## Shared sync file

Both apps push/pull `bsns-ssh-sync.json` in the user-chosen folder. Android also
reads its pre-rename name `bsns-config-aesgcm-v1.json` (pull only) so a folder
synced before the rename still resolves; it always *writes* the canonical name.

## Field divergences each side absorbs

| Field            | iOS writes                              | Android writes            | Tolerance |
|------------------|-----------------------------------------|---------------------------|-----------|
| host `id`/`label`| present (iOS requires both on decode)   | now also emitted          | iOS decode defaults a missing `id`/`label` |
| key id           | `keyID`                                 | `keyId` + `keyID`         | both sides read `keyID`, fall back to `keyId` |
| trusted keys     | nested `{entries:{id:{keyType,blob}}}`  | flat `{id: base64Blob}`   | both sides read either; key type recovered from the blob |
| settings         | full field set                          | subset (5 fields)         | missing fields fall back to app defaults |

## Golden fixture A — Android-shaped bundle (must import on iOS)

```json
{
  "version": 1,
  "hosts": [
    {
      "id": "11111111-1111-4111-8111-111111111111",
      "label": "deploy@bastion.example.com",
      "host": "bastion.example.com",
      "port": 22,
      "user": "deploy",
      "keyId": "SHA256:abc",
      "keyID": "SHA256:abc",
      "useMosh": true
    }
  ],
  "knownHosts": {
    "bastion.example.com": "AAAAC3NzaC1lZDI1NTE5AAAAIAABAgMEBQYHCAkKCwwNDg8QERITFBUWFxgZGhscHR4f"
  },
  "settings": { "fontSize": 14, "scrollback": 5000, "cursorBlink": false, "keepAwake": true, "showKeyBar": true }
}
```

## Golden fixture B — iOS-shaped bundle (must import on Android)

```json
{
  "version": 1,
  "hosts": [
    {
      "id": "22222222-2222-4222-8222-222222222222",
      "label": "My Bastion",
      "host": "bastion.example.com",
      "port": 22,
      "user": "deploy",
      "keyID": "SHA256:abc",
      "useMosh": true
    }
  ],
  "knownHosts": {
    "entries": {
      "bastion.example.com": {
        "keyType": "ssh-ed25519",
        "blob": "AAAAC3NzaC1lZDI1NTE5AAAAIAABAgMEBQYHCAkKCwwNDg8QERITFBUWFxgZGhscHR4f"
      }
    }
  },
  "settings": {
    "theme": "bsns-dark", "fontFamily": "Menlo", "cursorStyle": "block",
    "bellMode": "haptic", "terminalType": "xterm-256color", "fontSize": 14,
    "scrollback": 5000, "keepAliveInterval": 30, "cursorBlink": true,
    "keepAwake": true, "optionAsMeta": true, "pinchZoom": true, "showKeyBar": true
  }
}
```

> Note: a fully runnable cross-platform parity test (à la the ImportParsers /
> ConfigEnvelope vectors) is deferred to the durable fix — moving config-bundle
> (de)serialization into the shared core. Today the contract lives in the two
> app-layer decoders, verified against these fixtures by inspection.
