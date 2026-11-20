package dev.holdmytrack.android

import androidx.credentials.exceptions.GetCredentialCancellationException
import androidx.credentials.exceptions.GetCredentialUnknownException
import androidx.credentials.exceptions.NoCredentialException
import org.junit.Assert.assertEquals
import org.junit.Test

class GoogleFailureTest {

    @Test
    fun `closing the picker says nothing`() {
        assertEquals(GoogleFailure.CANCELLED, GoogleFailure.of(GetCredentialCancellationException()))
    }

    @Test
    fun `no account to offer says so, not to try again`() {
        assertEquals(GoogleFailure.NO_ACCOUNT, GoogleFailure.of(NoCredentialException()))
    }

    @Test
    fun `any other failure is worth trying again`() {
        assertEquals(GoogleFailure.FAILED, GoogleFailure.of(GetCredentialUnknownException()))
    }
}
