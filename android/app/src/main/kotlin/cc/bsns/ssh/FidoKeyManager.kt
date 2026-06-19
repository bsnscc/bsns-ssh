package cc.bsns.ssh

import android.app.Activity
import android.os.Handler
import android.os.Looper
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import cc.bsns.ssh.core.OpenSshSkKey
import cc.bsns.ssh.core.SshEncoder
import cc.bsns.ssh.core.SshKeyFormat
import com.yubico.yubikit.android.YubiKitManager
import com.yubico.yubikit.android.transport.nfc.NfcConfiguration
import com.yubico.yubikit.android.transport.nfc.NfcNotAvailable
import com.yubico.yubikit.android.transport.usb.UsbConfiguration
import com.yubico.yubikit.core.YubiKeyDevice
import com.yubico.yubikit.core.fido.FidoConnection
import com.yubico.yubikit.core.smartcard.SmartCardConnection
import com.yubico.yubikit.fido.ctap.ClientPin
import com.yubico.yubikit.fido.ctap.CredentialManagement
import com.yubico.yubikit.fido.ctap.Ctap2Session
import com.yubico.yubikit.fido.ctap.PinUvAuthProtocolV2
import com.yubico.yubikit.fido.webauthn.AuthenticatorData
import java.nio.ByteBuffer
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.CancellationException
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * FIDO2 (CTAP2) security-key SSH keys (`sk-ecdsa-sha2-nistp256@openssh.com`). The
 * private key never leaves the YubiKey — we enroll a resident credential and, on
 * each connect, ask the token for an assertion (a touch, and a PIN if the key was
 * made verify-required). The FIDO PIN is held in memory after first use.
 *
 * rp/application is fixed to `ssh:bsns` so one resident credential works across
 * Android, iOS, and desktop OpenSSH — the application is baked into the public
 * key the server stores.
 *
 * Mirrors [YubiKeyManager]'s blocking discovery: the SSH owner thread blocks in
 * [assertion] while the user taps; [awaitingTap] drives the on-screen prompt.
 */
object FidoKeyManager {
    const val APPLICATION = "ssh:bsns"
    private val main = Handler(Looper.getMainLooper())
    private var activity: Activity? = null
    private var kit: YubiKitManager? = null
    private var pin: CharArray? = null

    /** Non-null while a YubiKey tap is awaited — the UI shows it as a prompt. */
    var awaitingTap by mutableStateOf<String?>(null)
        private set

    // The blocking op's result queue, exposed so [cancel] can unblock the waiting
    // worker. Set at the start of [withCtap] and nulled in its finally. @Volatile so
    // a UI-thread cancel sees the value the SSH worker just published.
    @Volatile private var pending: ArrayBlockingQueue<Result<*>>? = null

    val unlocked: Boolean get() = pin != null

    fun attach(activity: Activity) {
        this.activity = activity
        this.kit = YubiKitManager(activity.applicationContext)
    }

    fun setPin(value: String) { pin = value.toCharArray() }
    fun lock() { pin?.fill(' '); pin = null }

    /** An enrolled FIDO credential: the sk public blob, credential id (handle),
     *  application scope, and authenticator policy flags (presence/UV). */
    class Enrollment(val publicBlob: ByteArray, val credentialId: ByteArray, val application: String, val flags: Int)

    /** One FIDO assertion for an SSH sign: presence/UV flags + counter + raw r,s. */
    class SkSig(val flags: Byte, val counter: Long, val sigR: ByteArray, val sigS: ByteArray)

    /** Enroll: create a resident ES256 credential under rp "ssh:bsns"; returns its
     *  sk public blob + credential id. Blocking (prompts a tap). */
    fun enroll(pinValue: String): Enrollment {
        val chars = pinValue.toCharArray()
        val e = withCtap("Tap or insert your YubiKey to create a key") { ctap ->
            val clientDataHash = ByteArray(32).also { SecureRandom().nextBytes(it) }
            val proto = PinUvAuthProtocolV2()
            val clientPin = ClientPin(ctap, proto)
            val token = clientPin.getPinToken(chars, ClientPin.PIN_PERMISSION_MC, APPLICATION)
            val pinUvParam = proto.authenticate(token, clientDataHash)
            val rp = mapOf("id" to APPLICATION, "name" to "bsns.SSH")
            val userId = ByteArray(16).also { SecureRandom().nextBytes(it) }
            val user = mapOf("id" to userId, "name" to "ssh", "displayName" to "ssh")
            val params = listOf(mapOf("type" to "public-key", "alg" to -7))   // ES256 → ecdsa-sk
            val options = mapOf("rk" to true)                                 // resident → portable
            val cred = ctap.makeCredential(
                clientDataHash, rp, user, params, null, null, options, pinUvParam, proto.version, null, null,
            )
            val ad = AuthenticatorData.parseFrom(ByteBuffer.wrap(cred.authenticatorData))
            val acd = ad.attestedCredentialData ?: throw IllegalStateException("no credential data returned")
            val cose = acd.cosePublicKey                                      // COSE EC2: -2=x, -3=y
            val x = cose[-2] as ByteArray
            val y = cose[-3] as ByteArray
            val point = byteArrayOf(0x04) + x + y                             // uncompressed P-256 point
            // sk policy flag stored in the key: user-presence required (0x01), the
            // OpenSSH default for ecdsa-sk. The true per-signature flags come back
            // from the authenticator on each assertion regardless.
            Enrollment(SshKeyFormat.skEcdsaPublicBlob(point, APPLICATION), acd.credentialId, APPLICATION, 0x01)
        }
        pin = chars
        return e
    }

    /** Import existing resident credentials under rp "ssh:bsns" without creating
     *  a second key. This is what lets a credential created on iOS be used by the
     *  Android app with the same authorized_keys line. */
    fun importResident(pinValue: String): List<Enrollment> {
        val chars = pinValue.toCharArray()
        val credentials = withCtap("Tap or insert your YubiKey to import a key") { ctap ->
            val proto = PinUvAuthProtocolV2()
            val clientPin = ClientPin(ctap, proto)
            val token = clientPin.getPinToken(chars, ClientPin.PIN_PERMISSION_CM, null)
            val cm = CredentialManagement(ctap, proto, token)
            val out = mutableListOf<Enrollment>()
            cm.enumerateRps()
                .filter { (it.rp["id"] as? String) == APPLICATION }
                .forEach { rp ->
                    cm.enumerateCredentials(rp.rpIdHash).forEach { credential ->
                        @Suppress("UNCHECKED_CAST")
                        val cose = credential.publicKey as Map<Int, Any?>
                        val alg = (cose[3] as? Number)?.toInt()
                        val crv = (cose[-1] as? Number)?.toInt()
                        require(alg == -7 && crv == 1) { "FIDO credential is not ES256/P-256" }
                        val x = cose[-2] as? ByteArray ?: throw IllegalStateException("FIDO credential missing x coordinate")
                        val y = cose[-3] as? ByteArray ?: throw IllegalStateException("FIDO credential missing y coordinate")
                        require(x.size == 32 && y.size == 32) { "FIDO credential is not P-256" }
                        val point = byteArrayOf(0x04) + x + y
                        @Suppress("UNCHECKED_CAST")
                        val descriptor = credential.credentialId as Map<String, Any?>
                        val credentialId = descriptor["id"] as? ByteArray
                            ?: throw IllegalStateException("FIDO credential missing credential id")
                        out += Enrollment(SshKeyFormat.skEcdsaPublicBlob(point, APPLICATION),
                            credentialId, APPLICATION, 0x01)
                    }
                }
            out
        }
        if (credentials.isEmpty()) throw IllegalStateException("no portable bsns.SSH FIDO2 credential found")
        pin = chars
        return credentials
    }

    /** Produce an SSH sk assertion over `data` with the given credential. The
     *  authenticator signs authData||SHA256(data) — the native (non-WebAuthn) sk
     *  form libssh2 expects. Blocking (prompts a tap). */
    fun assertion(data: ByteArray, credentialId: ByteArray): SkSig {
        val p = pin ?: throw IllegalStateException("FIDO key is locked — enter your PIN")
        return withCtap("Tap or insert your YubiKey to sign in") { ctap ->
            val clientDataHash = MessageDigest.getInstance("SHA-256").digest(data)
            val proto = PinUvAuthProtocolV2()
            val clientPin = ClientPin(ctap, proto)
            val token = clientPin.getPinToken(p, ClientPin.PIN_PERMISSION_GA, APPLICATION)
            val pinUvParam = proto.authenticate(token, clientDataHash)
            val allow = listOf(mapOf("type" to "public-key", "id" to credentialId))
            val options = mapOf("up" to true)
            val assertions = ctap.getAssertions(
                APPLICATION, clientDataHash, allow, null, options, pinUvParam, proto.version, null,
            )
            val a = assertions.first()
            val authData = a.authenticatorData
            // authData = rpIdHash(32) || flags(1) || counter(4) || ... — a malformed
            // or fuzzed authenticator could return fewer bytes; validate before
            // indexing so we fail closed instead of throwing IndexOutOfBounds.
            require(authData.size >= 37) { "authenticator data too short: ${authData.size}" }
            val flags = authData[32]
            val counter = ((authData[33].toLong() and 0xff) shl 24) or
                ((authData[34].toLong() and 0xff) shl 16) or
                ((authData[35].toLong() and 0xff) shl 8) or
                (authData[36].toLong() and 0xff)
            val (r, s) = derToRS(a.signature)
            SkSig(flags, counter, r, s)
        }
    }

    // Run `op` on the next connected YubiKey, over its FIDO interface: USB =
    // FidoConnection (HID), NFC = SmartCardConnection (CCID). Blocks the caller.
    private fun <T> withCtap(prompt: String, op: (Ctap2Session) -> T): T {
        val act = activity ?: throw IllegalStateException("FIDO not ready (no activity)")
        val k = kit ?: throw IllegalStateException("FIDO not ready")
        val box = ArrayBlockingQueue<Result<T>>(1)
        @Suppress("UNCHECKED_CAST")
        pending = box as ArrayBlockingQueue<Result<*>>
        // Discovery can deliver the same key more than once (the USB attach
        // broadcast plus the already-connected enumeration, or a re-enumeration on
        // PIN/touch). Opening a second connection to a key already mid-operation
        // allocates a second CTAPHID channel whose responses interleave with the
        // first — the "wrong channel ID" failure. Claim the first device and ignore
        // the rest, and stop USB discovery as soon as we've claimed one so it can't
        // be re-opened underneath the running op. NFC discovery is left running:
        // its connection needs reader mode held for the duration of the tap.
        val claimed = AtomicBoolean(false)

        fun handle(device: YubiKeyDevice) {
            if (!claimed.compareAndSet(false, true)) return
            main.post { runCatching { k.stopUsbDiscovery() } }
            if (device.supportsConnection(FidoConnection::class.java)) {
                device.requestConnection(FidoConnection::class.java) { res ->
                    box.offer(runCatching { res.value.use { op(openCtap(it)) } })
                }
            } else {
                device.requestConnection(SmartCardConnection::class.java) { res ->
                    box.offer(runCatching { res.value.use { op(openCtap(it)) } })
                }
            }
        }

        main.post {
            awaitingTap = prompt
            try { k.startNfcDiscovery(NfcConfiguration(), act) { d -> handle(d) } }
            catch (e: NfcNotAvailable) { /* no NFC — rely on USB */ }
            k.startUsbDiscovery(UsbConfiguration().handlePermissions(true)) { d -> handle(d) }
        }
        try {
            val r = box.poll(60, TimeUnit.SECONDS)
                ?: throw java.io.IOException("no YubiKey detected — tap it to the phone or plug it in")
            return r.getOrThrow()
        } finally {
            pending = null
            main.post {
                awaitingTap = null
                runCatching { k.stopNfcDiscovery(act) }
                runCatching { k.stopUsbDiscovery() }
            }
        }
    }

    // Opening a Ctap2Session sends CTAPHID_INIT then GET_INFO. On some hosts another
    // process touches the key's FIDO HID interface intermittently, so that first
    // exchange comes back framed for the wrong channel (or a short read). INIT is
    // designed to (re)allocate and resync a channel, so retry the open a few times —
    // a later attempt can land in a clean window. Each attempt is logged so a field
    // failure shows the whole sequence in the diagnostic.
    private fun openCtap(c: FidoConnection): Ctap2Session = retryOpen { Ctap2Session(c) }
    private fun openCtap(c: SmartCardConnection): Ctap2Session = retryOpen { Ctap2Session(c) }

    private inline fun retryOpen(create: () -> Ctap2Session): Ctap2Session {
        var last: java.io.IOException? = null
        for (attempt in 1..6) {
            try {
                return create()
            } catch (e: java.io.IOException) {
                last = e
                try { Thread.sleep(200L * attempt) } catch (ignored: InterruptedException) {}
            }
        }
        throw last ?: java.io.IOException("couldn't open a CTAP session")
    }

    /** Cancel a pending tap: unblock the waiting worker with a failure, stop NFC/USB
     *  discovery, and clear the prompt. Safe to call when nothing is pending. */
    fun cancel() {
        pending?.offer(Result.failure<Any>(CancellationException("cancelled")))
        val act = activity
        val k = kit
        main.post {
            awaitingTap = null
            if (k != null) {
                if (act != null) runCatching { k.stopNfcDiscovery(act) }
                runCatching { k.stopUsbDiscovery() }
            }
        }
    }

    /** DER ECDSA signature → the r and s integer contents (big-endian, as the
     *  SSH/mpint encoding wants them — libssh2 length-prefixes each). */
    private fun derToRS(der: ByteArray): Pair<ByteArray, ByteArray> {
        var p = 2                                   // SEQUENCE tag + (short-form) length
        require(der[p].toInt() == 0x02) { "bad DER signature" }
        val rLen = der[p + 1].toInt() and 0xff; p += 2
        val r = der.copyOfRange(p, p + rLen); p += rLen
        require(der[p].toInt() == 0x02) { "bad DER signature" }
        val sLen = der[p + 1].toInt() and 0xff; p += 2
        val s = der.copyOfRange(p, p + sLen)
        return r to s
    }
}

/** A FIDO2 sk key the connect path recognizes. Unlike PIV/software signers it can't
 *  produce a plain signature body — it drives libssh2's sk-userauth path, whose
 *  native callback invokes [signSk]. It also builds the OpenSSH-format sk private
 *  key ([privatePem]) that libssh2 requires as `privatekeydata`. */
class FidoSkKey(
    val publicKeyBlob: ByteArray,
    val credentialId: ByteArray,
    val application: String,
    private val point: ByteArray,
    private val flags: Int,
) {
    /** The OpenSSH-format sk "private" key (the credential handle + metadata, no
     *  secret) libssh2 parses to learn the key handle/application. */
    val privatePem: String
        get() = OpenSshSkKey.ecdsaSkPem(point, application, credentialId, flags)

    /** Called by the native sk sign callback. Asks the authenticator for an
     *  assertion over `data` and returns the COMPLETE native sk-ecdsa SSH
     *  signature blob, which libssh2_userauth_publickey_raw emits verbatim:
     *    string "sk-ecdsa-sha2-nistp256@openssh.com"
     *    string (mpint r || mpint s)
     *    byte   flags
     *    uint32 counter */
    fun signSk(data: ByteArray): ByteArray {
        val sig = FidoKeyManager.assertion(data, credentialId)
        val ecdsaSig = SshEncoder.build {
            it.writeMPInt(sig.sigR)
            it.writeMPInt(sig.sigS)
        }
        return SshEncoder.build {
            it.writeString(OpenSshSkKey.SK_ECDSA_TYPE)
            it.writeString(ecdsaSig)
            it.writeByte(sig.flags.toInt() and 0xff)
            it.writeUInt32(sig.counter and 0xFFFFFFFFL)
        }
    }
}
