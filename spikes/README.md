# spikes/

Non-shipping architecture proofs-of-concept. Nothing in this directory is part
of the iOS or Android app — it is not linked into either build, ships in no
release artifact, and contains no secrets or credentials. It is kept in the repo
as a record of how a load-bearing design decision was de-risked.

## `libssh2-signcb/`

A standalone Swift Package Manager demo that proves the linchpin of the whole
key-handling architecture: that libssh2's client publickey-auth **sign-callback**
can authenticate against a real `sshd` using a signature produced by *our own*
code — so the private key never enters libssh2 (and, in the real app, never
leaves the Secure Enclave / Keystore / YubiKey).

It is a separate SPM package (not a target of either app) so the core stays free
of a system-`libssh2` dependency; it reuses the real `BsnsSSHCore` SSH wire codec
to frame ed25519 and ECDSA (P-256) signatures exactly as the on-device signers
do. Run it against a local `sshd` via `run.sh` (or `run-agent.sh` for the
agent-mode variant). The `.build/` output is gitignored.
