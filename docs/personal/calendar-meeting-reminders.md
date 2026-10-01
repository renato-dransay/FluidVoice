# Calendar meeting reminders

Automatic meeting detection only reacts to a call that is already running: the meeting app or tab must be open and using audio. Calendar reminders cover the moment before that. About a minute before a Mac Calendar event starts, FluidVoice shows a reminder with the event title, the start time and two actions:

- **Open** opens the event's call link.
- **Open & Transcribe** opens the link and starts an online-call recording named after the event, with its attendees offered as speaker names.

A reminder appears only for a timed event with a supported call link (Google Meet room, Zoom meeting, Microsoft Teams meeting, Whereby or Jitsi room) in its URL, location or notes. All-day events and invitations you declined are skipped. Each occurrence is offered once. The reminder stays until you act or dismiss it, or until five minutes after the start time or the end of the event, whichever comes first. It is not shown while a meeting is recording or processing, and the "Record this meeting?" prompt replaces it once the call is detected.

**Open & Transcribe** records the app that runs the call. For a Zoom or Teams link with the Zoom or Microsoft Teams app installed, FluidVoice waits up to 30 seconds for that app to come forward after the browser opens the link, and records it if it does. If the handoff is declined or blocked, or you join on the web, the browser that opened the link is recorded instead. Other links record that browser straight away. If the chosen app cannot be recorded, the reminder shows the error and nothing records.

The setting is **Remind me before calendar meetings**, under Settings > Meeting Detection and in FluidMeet settings. It is on by default but does nothing until calendar access is granted; turning it on asks for access if needed. Calendar data is read through EventKit, as for meeting names, and nothing is written to the calendar. Google Calendar events appear once the Google account is added under System Settings > Internet Accounts with Calendars enabled.

The scheduler logs `reminder-due`, `reminder-open`, `reminder-open-and-transcribe`, `reminder-dismissed`, `reminder-expired` and `reminder-start-failed` under the `MeetingCalendarReminders` source, without event titles or links.
