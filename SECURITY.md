# Security

## Reporting a problem

A security problem in Mail Dot should be reported privately. On the project's GitHub page, open the Security tab and choose Report a vulnerability. Security problems should not be opened as public issues, and a report should not include the text of real mail or any key.

## What Mail Dot is trusted with

Mail Dot holds permission to control Apple Mail and to use Accessibility on the Mac, and it holds the key to a private connection in the user's OpenAI account. It deserves the same care as any program with access to mail.

## The key

The key Mail Dot holds is restricted to running its connection (the Tunnels Read and Tunnels Use permissions). It cannot run a model or read anything else in the OpenAI account. Mail Dot keeps it in the macOS Keychain and never writes it to a file or a log. A key believed to be exposed should be deleted on OpenAI's API keys page, after which setup can create a new one.

## Supported versions

Only the latest release receives fixes.
