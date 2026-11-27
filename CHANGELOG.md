# What's new in Mail Dot

Each release lists what it fixes, what it adds and what it changes, newest first. While Mail Dot is in development, each release replaces the one before it on the [Releases page](https://github.com/JGKarlin/maildot/releases), so this page keeps the record of them all.

## 0.4.237, 27 November 2026

### Fixed

- Long replies are no longer refused with "Mail returned only part of this message's text."

## 0.4.236, 26 November 2026

### New

- Setup ends with a fifth step, Connect your accounts, which lists the accounts found in Mail with their calendars, each with Connect….
- Settings › Accounts has a Calendars section for Google Calendar, iCloud Calendar and Outlook Calendar.

### Changed

- Outlook.com and Microsoft 365 accounts work only through ChatGPT's Outlook Email connector, like Gmail and iCloud.

## 0.4.235, 26 November 2026

### Changed

- The reply panel labels its draft switcher Version ‹ n of N ›, and no longer shows "Not yet in your message".

## 0.4.234, 25 November 2026

### Fixed

- Long conversations in Mail no longer flicker and reload while Mail Dot is running.

## 0.4.233, 24 November 2026

### New

- Ask Dot remembers your filters between openings and restarts; Reset clears them.

## 0.4.232, 24 November 2026

### Changed

- Mail Dot's icon under a message's date now opens Ask Dot. Settings is the gear at the bottom right of every Mail Dot panel.

## 0.4.231, 24 November 2026

### Fixed

- Ask Dot always shows an answer it found, even when its list of searched accounts leaves one out.
- Tell Dot after you edit a draft revises your edited version.

### New

- After you tell Dot how to revise a draft, the new draft shows at once, and ‹ n of N › steps through the earlier drafts and your edits.
- Shift-Return adds a new line in every Tell Dot box; Return still sends.

## 0.4.230, 24 November 2026

### Fixed

- Open messages no longer flicker while Dot works on other mail: Mail Dot asks Mail to redraw only when a message you have open changes.

## 0.4.229, 24 November 2026

### Fixed

- A new message is read even when Mail has not yet supplied its subject; the sender and recipients must still be known.

## 0.4.228, 24 November 2026

### Fixed

- A message waiting its turn in Dot's queue is no longer given up on, and a late answer from Dot to an earlier request is still applied.

### New

- You can tell Dot how to write a reply while it is still checking or drafting the message.

## 0.4.226, 21 November 2026

### Changed

- The version number shows only in Mail Dot's settings.

## 0.4.225, 21 November 2026

### Changed

- The spoken mail report is removed.

## 0.4.224, 20 November 2026

### Fixed

- Dot's report panel widens to fit every language.

### Changed

- All Mail Dot panels share one layout: status and ⋯ menu at the top; actions, Call Dot and Settings at the bottom; one text box style with Dictate, Call Dot and Tell Dot.

## 0.4.223, 20 November 2026

### New

- When you reply to a message marked No reply needed, the panel asks how to reply before Dot drafts.
- The reply panel's bottom box has a Dictate button.

## 0.4.221, 19 November 2026

### Fixed

- The No reply needed status opens with a circled minus (⊖), so it no longer reads as a hyphen.

## 0.4.220, 19 November 2026

### New

- While Dot checks a received message, the Mail Dot pane and the banner show the message's place in Dot's queue, such as Checking · 4 ahead, and say when Dot is reading it.

## 0.4.219, 19 November 2026

### Changed

- The banner on a message opens with a plain symbol in the banner's own colour, such as ↻ Checking or ⊕ Cc only, instead of an emoji.
- Settings and the installer describe Dot as ChatGPT's always-on agent.

## 0.4.218, 18 November 2026

### Fixed

- A reply or draft window is found without asking the reader to close other windows.

### Changed

- Arriving mail is offered to Dot in batches of up to six, handed over one after another.
## 0.4.217, 18 November 2026: first release

The first installer published on the Releases page.

- Drafting in context, with a question from Dot where the context does not settle the reply, and the reader's answer kept so that Dot does not ask it again.
- Ask Dot: questions about the whole mailbox, answered with cited messages and a line for each account saying what was searched.
- Reports on each thread, with what is decided, what is open and who must act.
- Gmail and iCloud through their ChatGPT connectors only; other accounts through Mail, with an encrypted search index on the Mac and optional Search by Meaning.
- Requests the reader makes go ahead of automatic draft checks, and the reply panel says how many requests are ahead.
- Confirm before sending, on by default, under Sending in the Drafting Rules settings.
- Setup in four steps, ending on Mail Dot's own checks of the connection, with guidance when ChatGPT is signed out, a permission is refused or Dot stops; Remove Mail Dot in the app.
- A call from Mail opens first, and the request then goes into it.
- Setup and calls work whatever language the ChatGPT app is shown in.
- Automatic updates: a daily check of this repository's latest release, installed when Mail quits.
- Dot's subscriptions last a day, and Keep connected runs every six hours.

The installer is for Macs with Apple silicon running macOS 14 or later.

## Earlier source snapshots

The source was published as 0.4.168 and 0.4.189 on 15 November 2026, as 0.4.199 and 0.4.205 on 17 November 2026, and as 0.4.216 on 18 November 2026.
