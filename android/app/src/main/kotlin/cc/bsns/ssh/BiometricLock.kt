package cc.bsns.ssh

import android.content.Context
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity

private const val AUTHENTICATORS =
    BiometricManager.Authenticators.BIOMETRIC_WEAK or BiometricManager.Authenticators.DEVICE_CREDENTIAL

/** True if the device can authenticate by biometric or device credential (PIN/pattern). */
fun biometricAvailable(context: Context): Boolean =
    BiometricManager.from(context).canAuthenticate(AUTHENTICATORS) == BiometricManager.BIOMETRIC_SUCCESS

/** True if a *strong* (class-3) biometric is enrolled — the only kind that can
 *  unlock a Keystore key for signing via a CryptoObject. Gates the opt-in
 *  biometric-protected device key. */
fun strongBiometricAvailable(context: Context): Boolean =
    BiometricManager.from(context)
        .canAuthenticate(BiometricManager.Authenticators.BIOMETRIC_STRONG) == BiometricManager.BIOMETRIC_SUCCESS

private fun promptUnlock(activity: FragmentActivity, onSuccess: () -> Unit) {
    val prompt = BiometricPrompt(
        activity, ContextCompat.getMainExecutor(activity),
        object : BiometricPrompt.AuthenticationCallback() {
            override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) = onSuccess()
        },
    )
    prompt.authenticate(
        BiometricPrompt.PromptInfo.Builder()
            .setTitle("Unlock bsns.ssh")
            .setSubtitle("Unlock to use your saved hosts, keys, and sessions.")
            .setAllowedAuthenticators(AUTHENTICATORS)
            .build(),
    )
}

/** Full-screen lock shown when app-lock is on and the app isn't unlocked yet.
 *  Auto-prompts on appear; a button re-triggers if the prompt is dismissed. */
@Composable
fun LockScreen(onUnlock: () -> Unit) {
    val activity = LocalContext.current as? FragmentActivity
    LaunchedEffect(Unit) { activity?.let { promptUnlock(it, onUnlock) } }
    Column(
        Modifier.fillMaxSize().padding(32.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text("bsns.\$_", fontFamily = FontFamily.Monospace, fontSize = 26.sp)
        Text("Locked", fontSize = 15.sp, color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(top = 8.dp, bottom = 24.dp))
        Button(onClick = { activity?.let { promptUnlock(it, onUnlock) } }) { Text("Unlock") }
    }
}
