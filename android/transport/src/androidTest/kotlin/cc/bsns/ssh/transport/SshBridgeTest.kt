package cc.bsns.ssh.transport

import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.util.Base64

/**
 * The transport spike's payoff: authenticate to a real SSH server using a
 * non-extractable Keystore key, signing through the JNI bridge. Runs on the
 * arm64 emulator against the docker openssh on the host (10.0.2.2:2222).
 *
 * Generates a TEE-backed Keystore EC key, installs its public key on the server
 * (password), then connects with public-key auth where every signature is made
 * in the Keystore via the native sign callback.
 */
@RunWith(AndroidJUnit4::class)
class SshBridgeTest {

    @Test
    fun authenticatesWithNonExtractableKeystoreKey() {
        val signer = KeystoreSigner("bsns-spike-key")
        val authLine = "ecdsa-sha2-nistp256 " +
            Base64.getEncoder().encodeToString(signer.publicKeyBlob) + " bsns-spike"

        val bridge = SshBridge()
        assertTrue(
            "failed to install the Keystore public key on the server",
            bridge.nativeInstallKey("10.0.2.2", 2222, "tester", "testpw", authLine),
        )

        val out = bridge.nativeAuthAndExec(
            "10.0.2.2", 2222, "tester", signer.publicKeyBlob, signer,
            "echo KEYSTORE_AUTH_OK; uname -m",
        )
        assertNotNull("public-key auth via the Keystore returned null", out)
        assertTrue("unexpected output: $out", out!!.contains("KEYSTORE_AUTH_OK"))
    }
}
