# Calendar meeting reminders

Automatic meeting detection only reacts to a call that is already running: the meeting app or tab must be open and using audio. Calendar reminders cover the moment before that. About a minute before a Mac Calendar event starts, FluidVoice shows a reminder with the event title, the start time and two actions:

- **Open** opens the event's call link.
- **Open & Transcribe** opens the link and starts an online-call recording named after the event, with its attendees offered as speaker names.

A reminder appears only for a timed event with a supported call link (Google Meet room, Zoom meeting, Microsoft Teams meeting, Whereby or Jitsi room) in its URL, location or notes. All-day events and invitations you declined are skipped. Each occurrence is offered once. The reminder stays until you act or dismiss it, or until five minutes after the start time or the end of the event, whichever comes first. It is not shown while a meeting is recording or processing, and the "Record this meeting?" prompt replaces it once the call is detected.

**Open & Transcribe** records the app that runs the call. For a Zoom or Teams link with the Zoom or Microsoft Teams app installed, FluidVoice waits up to 30 seconds for that app to come forward after the browser opens the link, and records it if it does. If the handoff is declined or blocked, or you join on the web, the browser that opened the link is recorded instead. Other links record that browser straight away. If the chosen app cannot be recorded, the reminder shows the error and nothing records.

The calendar also helps automatic detection find a browser call that is already running. A browser call normally counts only after the browser has been in front since FluidVoice started, so a call left behind other windows, or one running when FluidVoice was reopened, stayed undetected. Now a call in a background browser tab is detected when the browser's microphone is live and a calendar event happening now links to that same room. The calendar is checked at most once a minute per room; a different room on the calendar, or the room open with no live microphone, never counts. This works while either calendar names or calendar reminders is on and calendar access is granted, and logs `calendar-corroborated` under `MeetingAutoDetector`.

The setting is **Remind me before calendar meetings**, under Settings > Meeting Detection and in FluidMeet settings. It is on by default but does nothing until calendar access is granted; turning it on asks for access if needed. Calendar data is read through EventKit, as for meeting names, and nothing is written to the calendar. Google Calendar events appear once the Google account is added under System Settings > Internet Accounts with Calendars enabled.

The scheduler logs `reminder-due`, `reminder-open`, `reminder-open-and-transcribe`, `reminder-dismissed`, `reminder-expired` and `reminder-start-failed` under the `MeetingCalendarReminders` source, without event titles or links.

## Upcoming events and the call headline

FluidMeet's meeting home shows a **Coming up** section below the recording card: the next five calendar events by default, up to seven days ahead, with **View all** for the rest. Each row shows the start time and day ("Today", "Tomorrow" or the weekday), a slim bar in the calendar's color, the title, and a detail line with the length, the call service and how many other people are invited. A hollow bar and "Not accepted yet" mark an invitation you have not accepted. All-day events and declined invitations are left out.

From five minutes before an event with a supported call link until it ends, the row is tinted, shows "In 4 min" or "Now", and offers **Join**, which opens the link, and **Transcribe**, which works like the reminder's Open & Transcribe. When automatic detection has already found that call, **Transcribe** records it in place instead of opening the link again. The list needs calendar access and either calendar names or calendar reminders turned on, and refreshes every 30 seconds and whenever the calendar changes.

When automatic detection has found a call, the card names it instead of only the app: the calendar event whose link is the detected room gives the title, then the meeting name the page exposes, then the service, for example "OTC Refinement" with "Google Meet in Vivaldi. Vivaldi and your mic will be recorded." A recording started from the card is named after that event when calendar names are on. The list logs `upcoming-join`, `upcoming-open-and-transcribe` and `upcoming-start-failed` under `MeetingUpcomingEvents`, without titles or links.
