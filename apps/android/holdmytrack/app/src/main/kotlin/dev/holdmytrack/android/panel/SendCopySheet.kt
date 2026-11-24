package dev.holdmytrack.android.panel

import android.annotation.SuppressLint
import android.content.Context
import android.view.LayoutInflater
import android.view.View
import android.view.inputmethod.EditorInfo
import android.widget.TextView
import androidx.core.widget.doAfterTextChanged
import com.google.android.material.textfield.TextInputEditText
import dev.holdmytrack.android.R
import dev.holdmytrack.android.net.FailureText
import dev.holdmytrack.android.net.HoldMyTrackApi
import dev.holdmytrack.android.net.Trip

/**
 * Send a copy, the web's `SendCopyDialog.tsx` (`docs/SPEC.md` FR-13.6, FR-13.7), as a [FormSheet]
 * over `sheet_send_copy`: the email address to send a copy of the Trip to. Send waits for an
 * address ([TripForms]), and the keyboard's Send does the same as tapping it. Once
 * sent the sheet stays up on "Sent to …", with the same words whether or not the address has an
 * account, since the server answers the same either way, and the field cleared for another
 * address; a refusal stays on screen as typed.
 */
object SendCopySheet {

    @SuppressLint("InflateParams") // FormSheet adds the content to its own body.
    fun show(context: Context, trip: Trip) {
        val content = LayoutInflater.from(context).inflate(R.layout.sheet_send_copy, null)
        val email: TextInputEditText = content.findViewById(R.id.send_copy_email)
        val status: TextView = content.findViewById(R.id.send_copy_status)
        var sending = false
        var sent = false
        lateinit var sheet: FormSheet

        fun address() = email.text?.toString().orEmpty().trim()
        fun render() {
            sheet.setAction(
                context.getString(if (sending) R.string.trip_sending else R.string.trip_send_confirm),
                TripForms.actionEnabled(address(), sending),
            )
            sheet.setDismissLabel(context.getString(if (sent) R.string.trip_send_close else android.R.string.cancel))
            sheet.setBusy(sending)
            email.isEnabled = !sending
        }

        fun submit() {
            val to = address()
            if (!TripForms.actionEnabled(to, sending)) return
            sending = true
            status.visibility = View.GONE
            render()
            HoldMyTrackApi.sendTrip(trip.id, to) { result ->
                sending = false
                result.onSuccess {
                    sent = true
                    email.setText("")
                    status.text = context.getString(R.string.trip_send_done, to)
                    status.setTextColor(context.getColor(R.color.hmt_ink))
                }.onFailure { failure ->
                    status.text = FailureText.of(failure, context.getString(R.string.trip_save_failed))
                    status.setTextColor(context.getColor(R.color.hmt_danger))
                }
                status.visibility = View.VISIBLE
                render()
            }
        }

        sheet = FormSheet(context, context.getString(R.string.trip_send_title, trip.name), content, ::submit)
        email.doAfterTextChanged { render() }
        email.setOnEditorActionListener { _, actionId, _ ->
            if (actionId != EditorInfo.IME_ACTION_SEND) return@setOnEditorActionListener false
            submit()
            true
        }
        render()
        sheet.show()
        email.requestFocus()
    }
}
