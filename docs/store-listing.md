# Store listing — release draft, 2026-10-06

Use this copy only for features verified on the submitted platform and build.
Review privacy answers separately using `privacy-manifest-audit.md`.

## App Store

**Name:** bsns.SSH

**Subtitle:** SSH, mosh & secure keys

**Promotional text:** SSH, mosh, and SFTP for your own servers. Free and open source, with no ads or subscription. Built by bsns.cc.

**Keywords:** terminal,sftp,tmux,server,console,shell,sysadmin,devops,port forwarding,remote

**Description:**

```text
SSH from your iPhone or iPad, with keys and settings you control. bsns.SSH is free and open source. There are no ads, subscriptions, or bsns.cc accounts to create.

GET BACK TO YOUR TERMINAL
Open multiple terminal sessions, search output, browse files with SFTP, and forward local ports. Use optional mosh for roaming connections and tmux on your host to keep work running while you switch devices. Show or hide the phone keyboard when you need more room to read.

CHOOSE HOW YOU SIGN IN
Generate a Secure Enclave key on your device, use a supported security token, or import a software key. Hardware private keys stay in hardware. Software keys can be included in encrypted backups you choose to create.

KEEP YOUR SETUP WITH YOU
Save encrypted configuration to a folder you choose. On supported Apple devices, shared workspaces organize your hosts, directories, and terminal windows. Restoring saved tmux windows uses a helper installed on the host; the setup guide walks you through it.

Pair your devices to request signatures from your phone or send questions and notices. Signing uses a direct encrypted connection. Background questions and notices use encrypted messages in your private iCloud database and Apple push notifications.

NO ADS OR ANALYTICS
No ads, tracking SDKs, or automatic diagnostic uploads. The privacy policy explains connections to your servers, optional storage and cloud services, and the metadata those services handle.

OPEN SOURCE
Read the source, report issues, or build it yourself:
https://github.com/bsnscc/bsns-ssh

We use bsns.SSH while building bsns.cc, our software for running a small business. The SSH client is a separate, free tool. You do not need to use bsns.cc to use it.
```

**Support URL:** https://github.com/bsnscc/bsns-ssh/issues

**Marketing URL:** https://github.com/bsnscc/bsns-ssh

Use the repository until a dedicated SSH product page is published. The root of
`tools.bsns.cc` currently opens the domain-checking tool.

**Privacy URL:** https://tools.bsns.cc/open-source/privacy

**Privacy label:** Reconcile the final data inventory and CloudKit metadata with
Apple's questionnaire before submission. Do not copy an earlier answer blindly.

## App Review notes

Replace all placeholders in App Store Connect, not in this public repository.
Credentials belong in the private review fields. Use a dedicated test account.

```text
bsns.SSH is a general-purpose SSH, mosh, and SFTP client. It does not require a bsns.cc account, purchase, subscription, or external security token.

The previous review could not reach our SSH service on port 22. The review server now accepts SSH on TCP port 443. This is SSH on port 443, not an HTTPS website.

REVIEW SERVER
Host: <REVIEW_HOST>
Port: 443
User: <REVIEW_USER>
Password: supplied in the private review credentials field
Expected SSH host-key fingerprint: <SHA256_FINGERPRINT>

FIRST CONNECTION
1. Open Connect and enter the host, port 443, username, and supplied password.
2. Leave Use mosh OFF for this test. No VPN is needed.
3. Tap Connect. Compare the first-connection host-key fingerprint with the value above, then trust this test host.
4. Run whoami, pwd, and ls. The home directory contains sample files for SFTP.
5. Use the keyboard button to hide and restore the phone keyboard. Find searches terminal output.
6. Browse files (SFTP) uses this same endpoint. Upload or download a sample file.

The account will remain available throughout review and any follow-up. It has no production data or administrator privileges.

OPTIONAL FEATURES
Mosh requires mosh-server on the host and UDP access in addition to SSH on port 443. If UDP is blocked, use plain SSH; changing the SSH port does not tunnel mosh over TCP.
Hardware security tokens, paired-device signing, iCloud messages, sync, and workspace recovery are optional. Basic SSH can be reviewed with only the supplied password. Paired-device and cloud features have additional setup described in the attached demonstration video.

The app's associated domain supports Apple's security-key/passkey authentication flow. Optional cloud messaging uses CloudKit and Apple push notifications; encrypted config sync uses the user's selected file provider. There are no advertising or analytics SDKs.

Demonstration video: <VIDEO_URL_MATCHING_SUBMITTED_BUILD>
Contact: <REVIEW_CONTACT>
```

Attach a video of the submitted build on a physical device showing any optional
hardware-dependent feature that cannot be exercised with the demo credentials.
Confirm every claim about the review VM above before pasting the notes.

## Google Play

**Title:** bsns.SSH

**Short description:** Free SSH and mosh client with secure keys, SFTP, and encrypted config sync.

Use platform-specific copy: Android Keystore backing varies by device. Do not
claim Apple-only workspace, CloudKit, passkey, or notification features on Android.
Confirm the actual Android release and Data safety answers separately.

## What's new

First public store release. Include only features in the selected release binary.

## Screenshot shot-list

Use current captures from the release candidate, with harmless demo hosts and
files. Keep terminal output large enough to read in the store preview. The
[launch plan](launch-plan.md) supplies the recording sequence and full captions.

1. Connected terminal with the phone keyboard hidden: “More room to read.”
2. Named sessions or workspaces: “Keep your hosts organized.”
3. Key list with the actual key type visible: “Choose where your keys live.”
4. SFTP sample files: “Move a file without leaving the app.”
5. Encrypted configuration sync: “Keep your setup with you.”

Capture iPhone and iPad layouts separately at the sizes requested by App Store
Connect. Make Android assets from the Android app. Do not reuse a platform's
feature claim on another platform without verifying it there. Check the icon
on a real home screen before approving the final assets.
