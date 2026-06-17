package cc.bsns.ssh

import android.os.Handler
import android.os.Looper
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import cc.bsns.ssh.transport.KeyAuthorizer
import java.io.IOException
import java.security.Signature
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.TimeUnit

/**
 * Gates each use of an auth-required Keystore key behind a strong (class-3)
 * biometric prompt, bound to the signing operation via a
 * `BiometricPrompt.CryptoObject`. The SSH owner thread calls [authorize] inside
 * the native sign callback and blocks here while the system sheet is shown — the
 * same blocking-bridge shape as the YubiKey tap flow. On success the `Signature`
 * is unlocked for that single signature; cancel/timeout/error throws so the
 * connection fails closed.
 */
class BiometricKeyAuthorizer(private val activity: FragmentActivity) : KeyAuthorizer {
    private val main = Handler(Looper.getMainLooper())

    override fun authorize(reason: String, signature: Signature) {
        val box = ArrayBlockingQueue<Result<Unit>>(1)
        main.post {
            val prompt = BiometricPrompt(
                activity, ContextCompat.getMainExecutor(activity),
                object : BiometricPrompt.AuthenticationCallback() {
                    override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                        box.offer(Result.success(Unit))
                    }
                    // A non-terminal failed attempt (wrong finger) leaves the sheet
                    // up; only a terminal error resolves the wait.
                    override fun onAuthenticationError(code: Int, msg: CharSequence) {
                        box.offer(Result.failure(IOException(msg.toString())))
                    }
                },
            )
            val info = BiometricPrompt.PromptInfo.Builder()
                .setTitle("Authorize SSH key")
                .setSubtitle(reason)
                .setNegativeButtonText("Cancel")
                // CryptoObject signing requires a class-3 (STRONG) biometric; a
                // device-credential fallback can't unlock the key for signing.
                .setAllowedAuthenticators(BiometricManager.Authenticators.BIOMETRIC_STRONG)
                .build()
            try {
                prompt.authenticate(info, BiometricPrompt.CryptoObject(signature))
            } catch (e: Exception) {
                box.offer(Result.failure(e))
            }
        }
        val r = box.poll(60, TimeUnit.SECONDS)
            ?: throw IOException("biometric authorization timed out")
        r.getOrThrow()
    }
}
