# Privacy Policy — bsns.SSH

_Effective 2026-10-06. Release draft: publish this revision with the corresponding app update._

This policy covers the bsns.SSH apps for iOS, iPadOS, macOS, and Android.
The hosted bsns.cc suite is a separate product with its own
[privacy policy](https://bsns.cc/privacy). Feature availability varies by platform.

## What we receive

bsns.SSH has no advertising, tracking, analytics, or automatic crash-reporting
service operated by us. You do not need a bsns.cc account. Your terminal sessions,
keys, files, and configuration are not sent to a developer-operated collection
service. The source is available at <https://github.com/bsnscc/bsns-ssh>.

The app does transmit data to servers and services you use for its features.
Encryption does not hide connection addresses, timing, or all routing metadata
from those services. The sections below describe these flows.

## Connections and services

- **SSH, mosh, SFTP, and forwarding.** The app connects to hosts, jump hosts,
  addresses, and ports you configure. SSH uses TCP; optional mosh also uses UDP.
  Saved alternate addresses may be probed to find a reachable route. Servers
  receive the commands, files, or forwarded traffic you send and may keep their
  own logs. Their operators control those systems.
- **Configuration sync and device handoff.** Optional sync uses a folder you
  select through an OS file provider. Configuration and handoff payloads are
  encrypted on the device before upload. The provider receives encrypted data
  and ordinary file/service metadata, and operates under its own terms. Export
  without a passphrase creates a readable configuration file without private
  keys; encrypted export can include exportable software private keys.
- **Phone as a key.** Paired devices communicate directly over a local network,
  nearby wireless connection, or configured private-network address. Pairing
  protects signing requests and responses. Hardware private keys are not
  transferred. Local discovery can generate Bonjour/mDNS traffic.
- **Questions, notices, and answers between devices.** On supported Apple
  devices, the optional iCloud relay stores sealed messages in your private
  CloudKit database. Apple delivers notifications through its push service.
  Message content is encrypted with pairing keys before leaving the sending
  device and decrypted on the receiving device. Apple handles ciphertext,
  destination device identifiers, message type, record identifiers, timestamps,
  and delivery/account metadata. This is a cloud-mediated feature, not a direct
  peer connection. We do not receive the plaintext through this service.
- **Links you open.** Opening a terminal link in a browser contacts that website.
  Its privacy policy applies.

If you choose a demonstration SSH host operated by us, that server receives the
connection information and commands/files you send, just like any other SSH
server. Use it only for testing, never for private files, credentials, or work.
It is not an automatic telemetry destination.

## Notifications and retention

A receiving Apple device may decrypt a message in its notification extension so
that the notification shows the question and answer choices. Your OS notification
preview settings determine whether someone looking at the screen can see it.

The relay attempts to delete question records when they are retracted or expire
on the sending device, and answer records after the sender processes them.
Offline devices, interrupted cleanup, or service errors can delay deletion;
there is no guaranteed server-side expiry. CloudKit and your storage provider's
retention and backup behavior also apply. Local message history and settings
remain on your devices until removed there.

## Keys and local storage

Hardware-backed keys remain in the Secure Enclave, a security token, or the
Android Keystore. Android hardware backing depends on the device; the app shows
whether backing is hardware or software. Exportable software keys are stored
locally and can be included in an encrypted backup or sync bundle you request.
Consequently, encrypted software-key backups can leave the device; hardware
private keys cannot be exported by the app.

Saved hosts, trusted host keys, settings, workspaces, snippets, and command
history are stored locally. Optional configuration sync carries supported
configuration categories; command history is not included. Local diagnostic logs
can contain connection details or error messages. They are not uploaded
automatically; review them before sharing a support report.

## Apple security-key and passkey services

On iOS, security-key/passkey authentication uses Apple's AuthenticationServices.
Apple validates the app's association with `tools.bsns.cc` using the public
associated-domain file. That file contains app identifiers, not your SSH
credentials. Signing does not send SSH credentials to that website. Passkeys may
sync through your iCloud Keychain according to Apple's settings and policies;
external security-token credentials stay on their token.

## Support, children, and changes

Information you voluntarily submit in an issue or private security report is
received by the maintainers and the service hosting that report. Do not include
private keys, passwords, or unredacted terminal transcripts. See
[SECURITY.md](SECURITY.md) for private vulnerability reporting.

The app is a developer tool and is not directed at children. We update the date
and public version history when this policy changes. Contact us through
<https://github.com/bsnscc/bsns-ssh/issues> for privacy questions, using the private
security-reporting route for sensitive information.
