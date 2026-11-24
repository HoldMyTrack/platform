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
 * Create trip and Edit trip, the web's `TripDialog.tsx` (`docs/SPEC.md` FR-13.2, FR-13.6), as a
 * [FormSheet] over `sheet_trip`: Name (required, up to 200 characters) and Description (optional,
 * up to 2000). The action waits for a Name ([TripForms]), and the keyboard's Done in
 * Name does the same as tapping it. The sheet stays up while its request runs and keeps a refusal
 * on screen with the fields as typed, closing once the server has answered with the Trip.
 */
object TripSheet {

    /** Create trip from [trackIds]; [summary] says what it's made of ("3 checked tracks (58 km)"). */
    fun create(context: Context, summary: String, trackIds: Collection<String>, onCreated: (Trip) -> Unit) {
        show(
            context,
            title = R.string.trip_create_title,
            body = context.getString(R.string.trip_create_body, summary),
            trip = null,
            confirm = R.string.trip_create_confirm,
            busy = R.string.trip_creating,
            request = { name, description, done -> HoldMyTrackApi.createTrip(name, description, trackIds, done) },
            onDone = onCreated,
        )
    }

    /** Edit trip: [trip]'s name and description, saved with one `PATCH`. */
    fun edit(context: Context, trip: Trip, onSaved: (Trip) -> Unit) {
        show(
            context,
            title = R.string.trip_edit_title,
            body = null,
            trip = trip,
            confirm = R.string.edit_save,
            busy = R.string.edit_saving,
            request = { name, description, done -> HoldMyTrackApi.updateTrip(trip.id, name, description, done) },
            onDone = onSaved,
        )
    }

    @SuppressLint("InflateParams") // FormSheet adds the content to its own body.
    private fun show(
        context: Context,
        title: Int,
        body: String?,
        trip: Trip?,
        confirm: Int,
        busy: Int,
        request: (name: String, description: String, done: (Result<Trip>) -> Unit) -> Unit,
        onDone: (Trip) -> Unit,
    ) {
        val content = LayoutInflater.from(context).inflate(R.layout.sheet_trip, null)
        val bodyView: TextView = content.findViewById(R.id.trip_dialog_body)
        val name: TextInputEditText = content.findViewById(R.id.trip_dialog_name)
        val description: TextInputEditText = content.findViewById(R.id.trip_dialog_description)
        val error: TextView = content.findViewById(R.id.trip_dialog_error)
        bodyView.text = body
        bodyView.visibility = if (body == null) View.GONE else View.VISIBLE
        name.setText(trip?.name.orEmpty())
        description.setText(trip?.description.orEmpty())

        var saving = false
        lateinit var sheet: FormSheet
        fun nameText() = name.text?.toString().orEmpty().trim()
        fun render() {
            sheet.setAction(context.getString(if (saving) busy else confirm), TripForms.actionEnabled(nameText(), saving))
            sheet.setBusy(saving)
            name.isEnabled = !saving
            description.isEnabled = !saving
        }

        fun submit() {
            if (!TripForms.actionEnabled(nameText(), saving)) return
            saving = true
            error.visibility = View.GONE
            render()
            request(nameText(), description.text?.toString().orEmpty().trim()) { result ->
                saving = false
                result.onSuccess { saved ->
                    sheet.dismiss()
                    onDone(saved)
                }.onFailure { failure ->
                    render()
                    error.text = FailureText.of(failure, context.getString(R.string.trip_save_failed))
                    error.visibility = View.VISIBLE
                }
            }
        }

        sheet = FormSheet(context, context.getString(title), content, ::submit)
        name.doAfterTextChanged { render() }
        name.setOnEditorActionListener { _, actionId, _ ->
            if (actionId != EditorInfo.IME_ACTION_DONE) return@setOnEditorActionListener false
            submit()
            true
        }
        render()
        sheet.show()
        name.requestFocus()
        name.setSelection(name.length())
    }
}
