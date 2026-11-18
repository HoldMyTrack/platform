package dev.holdmytrack.android.panel

import android.annotation.SuppressLint
import android.content.Context
import android.text.Editable
import android.text.TextWatcher
import android.view.LayoutInflater
import android.view.View
import android.view.inputmethod.EditorInfo
import android.widget.TextView
import androidx.appcompat.app.AlertDialog
import com.google.android.material.dialog.MaterialAlertDialogBuilder
import com.google.android.material.textfield.TextInputEditText
import dev.holdmytrack.android.R
import dev.holdmytrack.android.net.HoldMyTrackApi
import dev.holdmytrack.android.net.Trip

/**
 * Create trip and Edit trip, the web's `TripDialog.tsx` (`docs/SPEC.md` FR-13.2, FR-13.6
 * item 7): Name (required, up to 200 characters) and Description (optional, up to 2000) over
 * `dialog_trip`. The confirm button stays disabled until Name has something besides spaces,
 * and the keyboard's Done in Name does the same as tapping it. The dialog stays up while its
 * request runs and keeps a refusal on screen, the fields as typed, closing only once the server
 * has answered with the Trip.
 */
object TripDialog {

    /** Create trip from [trackIds] — [summary] says what it's made of ("3 checked
     *  tracks (58 km)"). */
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

    @SuppressLint("InflateParams") // A dialog's content has no parent to inflate against.
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
        val content = LayoutInflater.from(context).inflate(R.layout.dialog_trip, null)
        val bodyView: TextView = content.findViewById(R.id.trip_dialog_body)
        val name: TextInputEditText = content.findViewById(R.id.trip_dialog_name)
        val description: TextInputEditText = content.findViewById(R.id.trip_dialog_description)
        val error: TextView = content.findViewById(R.id.trip_dialog_error)
        bodyView.text = body
        bodyView.visibility = if (body == null) View.GONE else View.VISIBLE
        name.setText(trip?.name.orEmpty())
        description.setText(trip?.description.orEmpty())

        val dialog = MaterialAlertDialogBuilder(context)
            .setTitle(title)
            .setView(content)
            .setPositiveButton(confirm, null)
            .setNegativeButton(android.R.string.cancel, null)
            .create()
        var saving = false

        fun positive() = dialog.getButton(AlertDialog.BUTTON_POSITIVE)
        fun nameText() = name.text?.toString().orEmpty().trim()
        fun renderButtons() {
            positive().isEnabled = !saving && nameText().isNotEmpty()
            positive().setText(if (saving) busy else confirm)
            dialog.getButton(AlertDialog.BUTTON_NEGATIVE).isEnabled = !saving
            name.isEnabled = !saving
            description.isEnabled = !saving
            dialog.setCancelable(!saving)
        }

        fun submit() {
            if (saving || nameText().isEmpty()) return
            saving = true
            error.visibility = View.GONE
            renderButtons()
            request(nameText(), description.text?.toString().orEmpty().trim()) { result ->
                saving = false
                result.onSuccess { saved ->
                    dialog.dismiss()
                    onDone(saved)
                }.onFailure { failure ->
                    renderButtons()
                    error.text = failure.message?.takeIf { it.isNotBlank() } ?: context.getString(R.string.trip_save_failed)
                    error.visibility = View.VISIBLE
                }
            }
        }

        name.addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) {}
            override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) {}
            override fun afterTextChanged(s: Editable?) = renderButtons()
        })
        name.setOnEditorActionListener { _, actionId, _ ->
            if (actionId != EditorInfo.IME_ACTION_DONE) return@setOnEditorActionListener false
            submit()
            true
        }
        dialog.setOnShowListener {
            positive().setOnClickListener { submit() }
            renderButtons()
        }
        dialog.show()
        name.requestFocus()
        name.setSelection(name.length())
    }
}
