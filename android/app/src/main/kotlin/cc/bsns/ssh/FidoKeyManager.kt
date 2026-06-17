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
import com.yubico.yubikit.fido.ctap.Ctap2Session
import com.yubico.yubikit.fido.ctap.PinUvAuthProtocolV2
import com.yubico.yubikit.fido.webauthn.AuthenticatorData
import java.nio.ByteBuffer
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.TimeUnit

/**
 * FIDO2 (CTAP2) security-key SSH keys (`sk-ecdsa-sha2-nistp256@openssh.com`). The
 * private key never leaves the YubiKey — we enroll a resident credential and, on
 * each connect, ask the token for an assertion (a touch, and a PIN if the key was
 * made verify-required). The FIDO PIN is held in memory after first use.
 *
 * rp/application is fixed to `ssh:bsns` so one resident credential works across
 * Android, desktop OpenSSH, and (later) iOS — the application is baked into the
 * public key the server stores.
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

        fun handle(device: YubiKeyDevice) {
            if (device.supportsConnection(FidoConnection::class.java)) {
                device.requestConnection(FidoConnection::class.java) { res ->
                    box.offer(runCatching { res.value.use { op(Ctap2Session(it)) } })
                }
            } else {
                device.requestConnection(SmartCardConnection::class.java) { res ->
                    box.offer(runCatching { res.value.use { op(Ctap2Session(it)) } })
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
            main.post {
                awaitingTap = null
                runCatching { k.stopNfcDiscovery(act) }
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
     *  assertion over `data` and packs it the way sshbridge.c unpacks it:
     *  flags(1) | counter(uint32 BE) | string(r) | string(s). */
    fun signSk(data: ByteArray): ByteArray {
        val sig = FidoKeyManager.assertion(data, credentialId)
        return SshEncoder.build {
            it.writeByte(sig.flags.toInt() and 0xff)
            it.writeUInt32(sig.counter and 0xFFFFFFFFL)
            it.writeString(sig.sigR)
            it.writeString(sig.sigS)
        }
    }
}
