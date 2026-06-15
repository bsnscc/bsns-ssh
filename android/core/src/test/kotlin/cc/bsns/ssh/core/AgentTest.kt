package cc.bsns.ssh.core

import java.security.KeyFactory
import java.security.PublicKey
import java.security.Signature
import java.security.spec.X509EncodedKeySpec
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/** Parity with the iOS `AgentTests`: identity listing + the SSH-agent protocol. */
class AgentTest {

    @Test fun listsIdentitiesInInsertionOrder() {
        val agent = Agent()
        agent.add(FileKey.generate(KeyAlgorithm.ED25519, "a"))
        agent.add(FileKey.generate(KeyAlgorithm.ED25519, "b"))
        val ids = agent.identities()
        assertEquals(2, ids.size)
        assertEquals("a", ids[0].comment)
        assertEquals("b", ids[1].comment)
    }

    @Test fun requestIdentitiesAnswerListsKeys() {
        val agent = Agent()
        val key = FileKey.generate(KeyAlgorithm.ED25519, "me@host")
        agent.add(key)
        val resp = agent.handleAgentMessage(byteArrayOf(SshAgentMessageType.REQUEST_IDENTITIES.code.toByte()))
        val d = SshDecoder(resp)
        assertEquals(SshAgentMessageType.IDENTITIES_ANSWER.code, d.readByte().toInt() and 0xFF)
        assertEquals(1L, d.readUInt32())
        assertContentEquals(key.publicKey.blob, d.readString())
        assertEquals("me@host", d.readStringUtf8())
    }

    @Test fun signRequestReturnsVerifiableSignature() {
        val agent = Agent()
        val key = FileKey.generate(KeyAlgorithm.ED25519)
        agent.add(key)
        val message = "challenge".toByteArray()
        val request = SshEncoder.build {
            it.writeByte(SshAgentMessageType.SIGN_REQUEST.code)
            it.writeString(key.publicKey.blob)
            it.writeString(message)
            it.writeUInt32(0)
        }
        val resp = agent.handleAgentMessage(request)
        val d = SshDecoder(resp)
        assertEquals(SshAgentMessageType.SIGN_RESPONSE.code, d.readByte().toInt() and 0xFF)
        val sigDec = SshDecoder(d.readString())
        assertEquals("ssh-ed25519", sigDec.readStringUtf8())
        val body = sigDec.readString()
        assertTrue(verifyEd25519(key.publicKey.blob, message, body))
    }

    @Test fun signUnknownKeyReturnsFailure() {
        val agent = Agent()
        agent.add(FileKey.generate(KeyAlgorithm.ED25519))
        val unknown = FileKey.generate(KeyAlgorithm.ED25519).publicKey.blob
        val request = SshEncoder.build {
            it.writeByte(SshAgentMessageType.SIGN_REQUEST.code)
            it.writeString(unknown)
            it.writeString("x".toByteArray())
            it.writeUInt32(0)
        }
        val resp = agent.handleAgentMessage(request)
        assertContentEquals(byteArrayOf(SshAgentMessageType.FAILURE.code.toByte()), resp)
    }

    // Reconstruct the Ed25519 public key from the SSH blob (string(type)||string(raw32))
    // by wrapping the 32 raw bytes in the fixed Ed25519 X.509 SPKI header.
    private fun verifyEd25519(blob: ByteArray, message: ByteArray, signature: ByteArray): Boolean {
        val d = SshDecoder(blob)
        d.readStringUtf8()            // "ssh-ed25519"
        val raw = d.readString()      // 32-byte public key
        val spki = byteArrayOf(0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00) + raw
        val pub: PublicKey = KeyFactory.getInstance("Ed25519").generatePublic(X509EncodedKeySpec(spki))
        val v = Signature.getInstance("Ed25519")
        v.initVerify(pub)
        v.update(message)
        return v.verify(signature)
    }
}
