package cc.bsns.ssh

import android.app.Activity
import android.os.Handler
import android.os.Looper
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import cc.bsns.ssh.core.SshKeyFormat
import com.yubico.yubikit.android.YubiKitManager
import com.yubico.yubikit.android.transport.nfc.NfcConfiguration
import com.yubico.yubikit.android.transport.nfc.NfcNotAvailable
import com.yubico.yubikit.android.transport.usb.UsbConfiguration
import com.yubico.yubikit.core.YubiKeyDevice
import com.yubico.yubikit.core.smartcard.SmartCardConnection
import com.yubico.yubikit.piv.KeyType
import com.yubico.yubikit.piv.PinPolicy
import com.yubico.yubikit.piv.PivSession
import com.yubico.yubikit.piv.Slot
import com.yubico.yubikit.piv.TouchPolicy
import java.security.PublicKey
import java.security.Signature
import java.security.interfaces.ECPublicKey
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.TimeUnit

/**
 * Talks to a YubiKey's PIV applet over NFC (tap) or USB-C. The private key never
 * leaves the token — we only read its public key and ask it to sign. The PIN is
 * held in memory after the first entry and cleared when the app backgrounds.
 * Mirrors the iOS `YubiKeyCoordinator`.
 *
 * Signing is *blocking*: the SSH owner thread calls [signRawRS] inside the JNI
 * sign callback and waits while the user taps the key; meanwhile [awaitingTap]
 * drives a "tap your YubiKey" overlay in the UI.
 */
object YubiKeyManager {
    /** PIV authentication slot (9A) — the SSH default. */
    private val SLOT = Slot.AUTHENTICATION
    private val main = Handler(Looper.getMainLooper())

    private var activity: Activity? = null
    private var kit: YubiKitManager? = null
    private var pin: CharArray? = null

    /** Non-null while a YubiKey tap is being awaited — the UI shows it as a prompt. */
    var awaitingTap by mutableStateOf<String?>(null)
        private set

    val unlocked: Boolean get() = pin != null

    fun attach(activity: Activity) {
        this.activity = activity
        this.kit = YubiKitManager(activity.applicationContext)
    }

    fun setPin(value: String) { pin = value.toCharArray() }
    fun lock() { pin?.fill(' '); pin = null }

    /** Enroll: read (or generate) the slot's P-256 key; returns its SSH public blob. Blocking. */
    fun enroll(pinValue: String): ByteArray {
        val chars = pinValue.toCharArray()
        val blob = withKey("Tap your YubiKey to read its key") { conn ->
            val piv = PivSession(conn)
            piv.verifyPin(chars)
            val pub: PublicKey = runCatching { piv.getSlotMetadata(SLOT).publicKey }
                .getOrElse { piv.generateKey(SLOT, KeyType.ECCP256, PinPolicy.ONCE, TouchPolicy.ALWAYS) }
            ecPublicKeyToSshBlob(pub)
        }
        pin = chars
        return blob
    }

    /** ECDSA-sign `data` with the slot key; returns the raw r‖s. Blocking (prompts a tap). */
    fun signRawRS(data: ByteArray): ByteArray {
        val p = pin ?: throw IllegalStateException("YubiKey is locked — enter your PIN")
        return withKey("Tap your YubiKey to sign in") { conn ->
            val piv = PivSession(conn)
            piv.verifyPin(p)
            val der = piv.sign(SLOT, KeyType.ECCP256, data, Signature.getInstance("SHA256withECDSA"))
            derToRawRS(der)
        }
    }

    // Run `op` on the next connected YubiKey (NFC tap or USB). Blocks the caller;
    // discovery + the op run on yubikit's threads, the result is handed back here.
    private fun <T> withKey(prompt: String, op: (SmartCardConnection) -> T): T {
        val act = activity ?: throw IllegalStateException("YubiKey not ready (no activity)")
        val k = kit ?: throw IllegalStateException("YubiKey not ready")
        val box = ArrayBlockingQueue<Result<T>>(1)

        fun handle(device: YubiKeyDevice) {
            device.requestConnection(SmartCardConnection::class.java) { result ->
                val r = runCatching { result.value.use { op(it) } }
                box.offer(r)   // first one wins; ignore later taps
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
}

/** A signer whose private key lives on a YubiKey PIV slot. The JNI sign callback
 *  invokes `sign([B): [B`; we block for the tap and return the SSH signature body. */
class YubiKeyPivKey(val publicKeyBlob: ByteArray) {
    fun sign(data: ByteArray): ByteArray =
        SshKeyFormat.ecdsaSignatureBody(YubiKeyManager.signRawRS(data))
}

/** A P-256 [ECPublicKey] → the SSH `ecdsa-sha2-nistp256` public blob. */
private fun ecPublicKeyToSshBlob(pub: PublicKey): ByteArray {
    val ec = pub as ECPublicKey
    val x963 = byteArrayOf(0x04) + fixed32(ec.w.affineX.toByteArray()) + fixed32(ec.w.affineY.toByteArray())
    return SshKeyFormat.ecdsaP256PublicBlob(x963)
}

/** DER ECDSA signature (SEQUENCE{INTEGER r, INTEGER s}) → raw 64-byte r‖s. */
private fun derToRawRS(der: ByteArray): ByteArray {
    var p = 2                                   // skip SEQUENCE tag + (short-form) length
    require(der[p].toInt() == 0x02) { "bad DER signature" }
    val rLen = der[p + 1].toInt() and 0xff; p += 2
    val r = der.copyOfRange(p, p + rLen); p += rLen
    require(der[p].toInt() == 0x02) { "bad DER signature" }
    val sLen = der[p + 1].toInt() and 0xff; p += 2
    val s = der.copyOfRange(p, p + sLen)
    return fixed32(r) + fixed32(s)
}

/** Strip sign-padding / left-pad a big-endian integer to a fixed 32 bytes. */
private fun fixed32(b: ByteArray): ByteArray {
    var start = 0
    while (start < b.size - 1 && b[start].toInt() == 0) start++
    val x = b.copyOfRange(start, b.size)
    return when {
        x.size == 32 -> x
        x.size > 32 -> x.copyOfRange(x.size - 32, x.size)
        else -> ByteArray(32 - x.size) + x
    }
}
