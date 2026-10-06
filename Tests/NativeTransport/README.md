# Native transport smoke test

Run on macOS after `bash app/vendor/build-cssh.sh`:

```sh
python3 Tests/NativeTransport/run.py
```

Requires Xcode command-line tools and the system `ssh-keygen` and `sshd`.
The runner generates temporary host and client keys, starts an SSH server bound
only to loopback on an ephemeral port, and links directly against the app's
rebuilt static transport. It removes its temporary files and stops the server
on completion. It does not change the system SSH configuration.

Checks Ed25519 and ECDSA authentication, command execution, SFTP file roundtrip,
symlink creation, realpath, and error-status parsing. The latter paths cover the
functional regression introduced by the initial SFTP security backport.

This does not exercise biometrics, hardware tokens, the app's signing callbacks,
or malformed-packet fuzzing; those require separate coverage.
