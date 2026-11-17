# Security

## Reporting a problem

A security problem in Mail Dot should be reported privately. The preferred way is the project's GitHub page: open the Security tab and choose Report a vulnerability. Reports can also be sent to mail_dot@icloud.com. Security problems should not be opened as public issues, and a report should not include the text of real mail or any key.

## What Mail Dot is trusted with

Mail Dot holds permission to control Apple Mail and to use Accessibility on the Mac, and it holds the key to a private connection in the user's OpenAI account. If the user turns on Search by Meaning and grants Full Disk Access, Mail Dot also holds that permission, which macOS defines for the whole disk; Mail Dot reads only the Mail folder with it. It deserves the same care as any program with access to mail.

## The key

The key Mail Dot holds is restricted to running its connection (the Tunnels Read and Tunnels Use permissions). It cannot run a model or read anything else in the OpenAI account. Mail Dot keeps it in the macOS Keychain and never writes it to a file or a log. A key believed to be exposed should be deleted on OpenAI's API keys page, after which setup can create a new one.

## The search index

Mail Dot's search index holds text of the mail in the accounts the user lets it read on the Mac. It is encrypted with SQLCipher. Its key is made on the Mac and kept in the login Keychain, readable only by Mail Dot and its helper, and is separate from the connection key. The index is excluded from Time Machine backups, and removing Mail Dot deletes both the index and its key.

## Supported versions

Only the latest release receives fixes.
