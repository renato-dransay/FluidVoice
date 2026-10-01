# Calendar meeting reminders

Automatic meeting detection only reacts to a call that is already running: the meeting app or tab must be open and using audio. Calendar reminders cover the moment before that. About a minute before a Mac Calendar event starts, FluidVoice shows a reminder with the event title, the start time and two actions:

- **Open** opens the event's call link.
- **Open & Transcribe** opens the link and starts an online-call recording named after the event, with its attendees offered as speaker names.

A reminder appears only for a timed event with a supported call link (Google Meet room, Zoom meeting, Microsoft Teams meeting, Whereby or Jitsi room) in its URL, location or notes. All-day events and invitations you declined are skipped. Each occurrence is offered once. The reminder stays until you act or dismiss it, or until five minutes after the start time or the end of the event, whichever comes first. It is not shown while a meeting is recording or processing, and the "Record this meeting?" prompt replaces it once the call is detected.

**Open & Transcribe** records the app that runs the call. For Zoom and Teams links that is the installed Zoom or Microsoft Teams app, which may take a few seconds to launch from the browser handoff; otherwise it is the browser that opens the link. If that app cannot be recorded, the reminder shows the error and nothing records.

The setting is **Remind me before calendar meetings**, under Settings > Meeting Detection and in FluidMeet settings. It is on by default but does nothing until calendar access is granted; turning it on asks for access if needed. Calendar data is read through EventKit, as for meeting names, and nothing is written to the calendar. Google Calendar events appear once the Google account is added under System Settings > Internet Accounts with Calendars enabled.

The scheduler logs `reminder-due`, `reminder-open`, `reminder-open-and-transcribe`, `reminder-dismissed`, `reminder-expired` and `reminder-start-failed` under the `MeetingCalendarReminders` source, without event titles or links.
