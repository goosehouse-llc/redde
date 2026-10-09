---
title: Redde Privacy Policy
---

# Redde Privacy Policy

**Effective date:** October 8, 2026
**Publisher:** Goosehouse LLC

Redde is a voice and chat client for an AI assistant that you run yourself. This policy explains what the app does with your information. The short version: Redde has no account, no analytics and no tracking, and your conversations go only to the server you configure. One optional feature, notifications when Redde is closed, uses a relay that we run. It holds your iPhone's push address and passes on notifications it cannot read.

## What Redde does not do

- Redde has no analytics, crash reporting, advertising, or tracking of any kind.
- Redde contains no third-party SDKs.
- Goosehouse LLC cannot see your conversations, your credentials, or how you use the app. None of that reaches us. The one service we run for Redde is the notification relay described below, and it is used only if you turn that feature on.
- Redde does not sell, share, or transfer personal information to anyone.

## Where your data goes

Redde sends messages, attachments, and voice transcripts only to the server address you enter in the app's setup. That server is one you control or choose: typically a self-hosted Hermes agent or an OpenAI-compatible model server on your own network. What that server does with your data is governed by your own configuration and, if you point Redde at a third-party hosted provider, by that provider's privacy policy. Redde puts no intermediary between you and that server.

Connections use HTTPS when the address you enter provides it. Because self-hosted servers on private networks often lack public certificates, Redde also allows plain HTTP connections to addresses you choose.

## Notifications when Redde is closed (optional, off by default)

iOS closes an app in the background after a few minutes, and from then on Redde cannot tell you that a reply is ready or that your assistant is waiting for you. If you want to be told anyway, you can pair your own Hermes server with your iPhone in Settings → Voice → Notify when Redde is closed. Nothing in this section happens unless you do.

Once paired, your Hermes server sends a notification when a reply finishes, when the assistant waits for you (to approve a command, answer a question, or enter a password or a secret), when a turn fails, and when a task it handed off comes back. Your server encrypts each one with a key that only it and your iPhone hold, and sends it to a relay operated by Goosehouse LLC (redde-push.goosehouse.org, hosted on Cloudflare). The relay hands it to Apple's push notification service, which delivers it, and your iPhone decrypts it.

What the relay holds for each pairing:

- your iPhone's push token: the address Apple issues so that notifications for Redde can reach that device;
- a one-way hash of a random secret, which lets your server, and nobody else, send to that token;
- whether the token belongs to a development or an App Store build, and when the iPhone last checked in.

What passes through and is not kept: the encrypted notifications. Inside the encryption is a short note saying what happened, the conversation's id and title, and up to the first 500 characters of the reply, or the command or question that is waiting. The relay has no key and cannot read any of it, and neither can Apple. The text Apple is given to display is always the same placeholder, which your iPhone replaces once it has decrypted the note. While you pair by scanning a code, the relay also holds your iPhone's half of the key exchange (a public key and an encrypted answer for your server) for at most ten minutes.

The relay has no accounts and nothing that says who you are: no name, no email address, no contact details. Like any internet service, it and its host see the network address a request comes from, and the host keeps routine request logs (the time, the path and the result, never a notification's content) for a few days. We use what the relay holds only to deliver your notifications. We do not combine it with anything else, share it, or sell it.

A pairing is deleted from the relay when you remove it in Redde (swipe it away under Notify when Redde is closed), when Apple reports that the token is no longer valid, for example after the app is deleted, or after 120 days in which the iPhone has not checked in. Your Hermes server keeps its own record of the pairing until it next tries to send; `hermes redde-push remove` deletes it there.

The Hermes server needs a small plugin for this. You can install it there yourself, or, when Redde is signed in to that server's Dashboard, have Redde ask the server to install it: the server then downloads the plugin from our public repository on GitHub. Redde passes the request to your own server and downloads nothing itself.

Notifications that Redde posts itself while it is running do not involve the relay.

## Speech

Voice input is transcribed on your device using Apple's on-device speech recognition, in voice mode and when you dictate into the message field. Audio never leaves the device. Only the resulting text is sent, and only to your configured server. Where a reply can be talked over (Settings → Voice → Talk over replies: with headphones, unless you change it), the microphone stays open in voice mode while the reply is read aloud, so that Redde can notice you starting to speak. That audio is handled the same way and nothing is recorded. The on-device voice used to read replies aloud also runs entirely on the device. If you enable a server-side text-to-speech voice in Settings, reply text is sent to the TTS server address you configure so it can return audio.

## Siri and Shortcuts

Redde offers Siri phrases and Shortcuts actions. When you use them, Apple's Siri processes your spoken command according to Apple's privacy policy, then hands control to Redde. Redde does not receive audio from Siri. Questions typed or dictated into the "Ask Redde a Question" shortcut action are sent only to your configured server. If you use Hermes profiles, Redde tells Siri and Shortcuts the names of the profiles it knows of, so that a phrase such as "Ask Work in Redde" is understood; Apple handles those names as it does any app's Siri phrases.

### Siri with Apple Intelligence (optional, off by default)

On iOS 27 and later you can turn on "Let Siri use Redde" in Settings. With it on, you can ask Siri to message your assistant in your own words, have Siri read replies aloud, and find Redde conversations in Siri and Spotlight. To do this, Apple Intelligence processes what you say to Siri, including the message itself, and Redde makes its recent conversations (titles, and message text unless the app lock is on) available to Siri and to the on-device Spotlight index. That processing is Apple's, under Apple's privacy policy. Redde still sends your messages only to your configured server, and none of it reaches Goosehouse LLC. Turning the setting off stops Siri's access and removes Redde's entries from Spotlight.

## Data stored on your device

- **Credentials** (server API keys, passwords, the tokens of a browser sign-in, and any custom headers you add for a server) are stored in the iOS Keychain, restricted to this device, and never leave it except in requests to the servers they belong to.
- **Notification pairings**, if you make any: the key shared with your Hermes server and what identifies the pairing at the relay, in the iOS Keychain on this device.
- **Conversation history**, **attachments** and **drafts** (what you have typed and not sent) are stored in the app's private container with iOS data protection. They are not synced or backed up by Redde, though they are included in your own iCloud or computer backups of the device like any app data.
- **Settings** are stored in the app's preferences on the device.
- **Shared items** sent to Redde from other apps via the share sheet are stored briefly in the app's private container until Redde opens and moves them into the composer.
- **Files from your server** that you open in Settings → Files are downloaded to a temporary folder so they can be shown, and removed the next time you open the file browser. Files you upload from there go only to your server.
- **What the widgets show** (the last reply, a command or question that is waiting for you, and how full the model's context is) is kept in a container the app shares with its widgets, on the device. With the app lock on, the widgets leave out commands, questions and titles.

You can delete conversations and attachments inside the app, remove credentials in Settings, or delete all data by deleting the app.

## Signing in through a browser

If your Hermes Dashboard signs people in with Google or another identity provider, Redde opens that Dashboard's own sign-in page in a system sign-in sheet. Your password goes to that page and its provider, never to Redde. What comes back is a pair of tokens issued by your Dashboard, which Redde keeps in the Keychain and sends only to that Dashboard. Goosehouse LLC is not involved.

## Apple Watch

The Apple Watch app gets your server's address and key from Redde on your iPhone and then talks to that server itself, or asks through the iPhone. The key is kept in the watch's Keychain. Questions are dictated with the watch's own dictation. When it talks to the server itself, the watch can list your recent conversations there and carry one on. The "Ask Redde" complication for a watch face only opens the app; it holds no data. Nothing goes anywhere else.

## Photos, camera, files, microphone, and Face ID

- Redde uses the system photo picker and file picker, which give the app access only to the items you select. A video that is too large to send is made smaller on the device first.
- The camera is used only when you choose Camera from the + menu or Scan a setup code in setup. A photo you take becomes an attachment in your message: it is kept with that conversation like any attachment and sent only to your server, and it is not saved to your photo library. Scanning a setup code reads the QR code on the device; no picture is kept or sent.
- The microphone is used only while you are talking with the app (voice mode, including while a reply that can be talked over is read aloud, and dictation into the message field), with the system's indicator showing, and only for on-device transcription.
- If you enable the app lock, or ask for your passwords to be included in a setup code for another device, Face ID or Touch ID is evaluated by iOS. Redde never receives biometric data.

## Setup links

A setup link (`https://redde.goosehouse.org/connect#…`) carries a server's connection in the part of the address after the `#`. Browsers do not send that part to a website, so it never reaches redde.goosehouse.org. With Redde installed, iOS opens the link in the app without loading the page at all. Without it, the page reads the link on your device only to show what it carries and hand it to the app; it sends nothing anywhere and collects nothing.

## Live Activities, widgets and Controls

Redde can show the progress of a reply in a Live Activity on the Lock Screen and in the Dynamic Island, and offers widgets and Control Center buttons. These display information already on your device and send nothing anywhere.

## Children

Redde is not directed at children under 13, and has no accounts and no personal details of anyone.

## Changes

If this policy changes, the new version will be posted at this address with an updated effective date. The October 2026 version added the optional notification relay; before it, Goosehouse LLC ran no service for Redde at all.

## Contact

Questions about this policy: hello@goosehouse.org
