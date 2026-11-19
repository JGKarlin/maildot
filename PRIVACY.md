# Privacy

Hooner LLC publishes Mail Dot. This page states what Mail Dot does with mail and with data. It applies to Mail Dot 0.4.220 and later, and was last updated on 19 November 2026.

## What Mail Dot collects

Mail Dot collects nothing. It has no server of its own. It contains no tracking, analytics or advertising, and it sends nothing to Hooner LLC or to its developer.

## Update checks

Once a day Mail Dot asks github.com whether a newer version of Mail Dot exists, and when one does, it downloads it from GitHub. These requests carry only what any web request carries, such as the Mac's network address and the version of the app making the request, and nothing about the user's mail or accounts. GitHub's own privacy statement governs what GitHub receives.

## ChatGPT's files on the Mac

To find the message field and the Start call button in the ChatGPT app in whatever language it is shown, Mail Dot reads the names of those controls from the ChatGPT app's own files on the Mac. It reads them locally, keeps only the names, and sends them nowhere.

## Where mail goes

Mail Dot connects Apple Mail on the Mac to Dot in the user's own ChatGPT account, and Dot receives mail through it. This holds for every account Mail Dot is given. How the mail reaches Dot differs by account, and so does who can limit it.

The text of a message goes to ChatGPT in three cases: when the user shares a message with Dot, when Mail Dot offers an important message to Dot for a draft or a report, and when Dot looks mail up to answer a question the user asked in Ask Dot. Automatic drafts can be switched off for any account.

For a Gmail or an iCloud account, Dot reads and searches through the connector for that service in ChatGPT. These accounts require their connector, and cannot be newly set up through Mail. An account that an earlier version of Mail Dot was already reading through Mail keeps working that way until its connector is confirmed; Mail Dot then switches it over and removes that account's index entries and embeddings from the Mac. ChatGPT connects to the provider directly: to Google through the sign-in the user gives it, and to Apple through an app-specific password that the user creates for iCloud Mail and adds in ChatGPT, which ChatGPT keeps in order to connect. Through that access Dot can read the whole mailbox on the provider's servers. Mail Dot does not hold that access or the password, keeps no copy of that mail, and plays no part in what Dot may read there. The user can withdraw the access in ChatGPT and, for iCloud, by revoking the app-specific password at Apple.

For an account that has no connector, such as an Exchange or other IMAP account, Dot reads through Mail on the Mac, and Mail Dot limits what it receives. Mail Dot searches its own index on the Mac and sends Dot only what the request needs. One search returns passages from at most 25 matching messages, and one read returns the full text of at most five messages. Dot may make several such requests to answer one question. Dot can reach only the folders the user has allowed, and it never receives the index itself or a mailbox as a whole.

Whatever Dot reads, from any account, is handled by OpenAI under the user's ChatGPT account. OpenAI's terms and privacy policy govern it, not this page. The connection between the Mac and ChatGPT is created in the user's own OpenAI account and carries only that user's requests.

## What stays on the Mac

Mail Dot keeps its settings, Dot's drafts and reports, and a record of its own actions in the user's macOS account. The Mac's login and disk encryption protect this data. Mail Dot encrypts its search index, described below, and does not separately encrypt the rest. The key that runs the connection is kept in the macOS Keychain.

## The search index

For a Gmail or an iCloud account, which ChatGPT reaches through a connector, Dot searches on the provider's servers, and Mail Dot keeps no index and no copy of the mail. Mail Dot holds no index entries or embeddings for an account once it is on its connector.

For an account that has no connector, Mail Dot keeps a search index on the Mac. It covers only the folders the user has allowed. It holds each message's sender, date, subject and own text, and it is stored in Mail Dot's private storage in the user's macOS account. A message deleted in Mail is removed from the index. The index is encrypted with SQLCipher. Its key is made on the Mac and kept in the login Keychain, readable only by Mail Dot and its helper. The index is excluded from Time Machine backups, and removing Mail Dot deletes both the index and its key. The index itself is never sent anywhere. Dot receives from it the results of the searches it makes to answer the user's question: passages from at most 25 matching messages for one search, and the full text of at most five messages for one read. Dot may make several such requests for one question, and what it receives is then handled by OpenAI under the user's ChatGPT account.

## Search by Meaning and Full Disk Access

Search by Meaning is chosen for each account separately and is off for every account unless the user turns it on. For an account with it on, Mail Dot computes embeddings of that account's indexed mail with the language model built into macOS. Turning it off for an account removes that account's embeddings. The computation happens on the Mac, the embeddings are stored beside the index, and neither the mail nor the embeddings are sent anywhere for this purpose. macOS may download the language model itself from Apple.

Search by Meaning asks for Full Disk Access so that Mail Dot can read past mail from Mail's files while Mail is closed. macOS grants this permission for the whole disk and has no narrower form. Mail Dot reads only the Mail folder, `~/Library/Mail`, checks that each file it opens lies inside that folder, writes nothing there, and skips junk and deleted mail. The permission can be withdrawn at any time in System Settings, under Privacy & Security; Mail Dot then reads mail through Mail, as it does without the permission.

## Sending mail

Mail Dot never sends a message by itself. A draft is sent only after the user presses Send in Mail Dot's panel on the Mac. By default Mail Dot then asks for one confirmation that names the recipients; the Confirm before sending setting can turn that second step off for sends the user starts in the panel. A send that Dot prepared during a voice call always waits for the user's confirmation on the Mac.

## Removing data

The Remove Mail Dot… button, in Mail Dot's window and in its setup window, moves the app, its Mail extension, its settings and its stored data to the Trash, and deletes the search index, with any embeddings, and Mail Dot's keys in the Keychain. The plugin and the scheduled task in ChatGPT, and the tunnel and its key on OpenAI's platform, are deleted in those accounts; the README lists them.

## Questions

Questions about this statement can be sent to mail_dot@icloud.com or raised on the project's Issues page on GitHub. Messages and reports should not include the text of real mail.
