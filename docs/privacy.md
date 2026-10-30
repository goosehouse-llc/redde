---
title: Redde Privacy Policy
---

# Redde Privacy Policy

**Effective date:** October 26, 2026
**Publisher:** Goosehouse LLC

Redde is a voice and chat client for an AI assistant that you run yourself. This policy explains what the app does with your information. The short version: Redde has no account, no analytics and no tracking, and your conversations go only to the server you configure. One optional feature, notifications when Redde is closed, uses a relay that we run. It holds your iPhone's push address and passes on notifications it cannot read.

## What Redde does not do

- Redde has no analytics, crash reporting, advertising, or tracking of any kind.
- Redde contains no third-party SDKs.
- Goosehouse LLC cannot see your conversations, your credentials, or how you use the app. None of that reaches us. The one service we run for Redde is the notification relay described below, and it is used only if you turn that feature on.
- Redde does not sell, share, or transfer personal information to anyone.

## Where your data goes

Redde sends messages, attachments, and voice transcripts only to the server address you enter in the app's setup (and, if you start a live voice call, to the voice service you chose, as described below). That server is one you control or choose: typically a self-hosted Hermes agent or an OpenAI-compatible model server on your own network. What that server does with your data is governed by your own configuration and, if you point Redde at a third-party hosted provider, by that provider's privacy policy. Redde puts no intermediary between you and that server.

Connections use HTTPS when the address you enter provides it. Because self-hosted servers on private networks often lack public certificates, Redde also allows plain HTTP connections to addresses you choose.

Link previews (Settings → Appearance) are off unless you turn them on. With them on, when a message in a conversation contains a web link, your device opens that page itself to show its title and picture under the message, the way Messages does. The website sees a visit from your device's network address, like any visit from Safari. Nothing else from the conversation is sent to it, and nothing goes to Goosehouse LLC. The preview is kept on your device so the page is opened only once.

When your assistant shows a map or places in a reply, the map is drawn by Apple Maps, and a place it names without coordinates is looked up with Apple's map search, under Apple's privacy policy, as the Maps app does. Unless you turn on Current Location, directions from where you are are worked out by Maps when you open them.

Current Location (Settings → Agent) is off unless you turn it on, and is set on each device. With it on, and location allowed for Redde, your device takes one approximate fix of where it is when you open Redde or ask about a place, at most every few minutes (never tracking, never in the background), has Apple's maps put it in words (the neighborhood and town), and keeps that on the device. Only when a message asks about places, directions, maps or the weather does Redde send that place to your own server with the message, in words and with coordinates rounded to about 100 meters. On your device, the same fix measures the walk to the places on a places card and draws the route on a map card. None of it goes to Goosehouse LLC. Turning it off deletes the place kept.

When your assistant shows the weather or the time somewhere, the place it names is looked up to find its forecast or its time zone. Redde's plugin on your Hermes server does this, asking Open-Meteo (open-meteo.com) with the place's name and then its coordinates, and Redde draws what comes back. Where the plugin hasn't filled the card in, your device looks the place up with Apple's map search and asks Open-Meteo for the forecast of its coordinates. Open-Meteo sees those requests coming from your server or your device; nothing else from the conversation is sent to it, and nothing goes to Goosehouse LLC. The time is drawn from your device's own clock. So that "what time is it" can be answered for where you are, Redde tells the plugin on your server your device's time zone and temperature units.

When you open Find Plugins (Settings → Plugins), your device downloads Nous Research's public catalog of Hermes plugins from hermes-agent.nousresearch.com, the same file your Hermes server reads, and keeps a copy for a few hours. Nous Research sees that request coming from your device; nothing else is sent with it. Searching the catalog happens on your device. Installing a plugin is asked of your own server, which fetches the plugin itself. A key you type for a plugin goes only to your server, into its settings file.

## Notifications when Redde is closed (optional, off by default)

iOS closes an app in the background after a few minutes, and from then on Redde cannot tell you that a reply is ready or that your assistant is waiting for you. If you want to be told anyway, you can pair your own Hermes server with your iPhone in Settings → Voice → Notify when Redde is closed. Nothing in this section happens unless you do.

Once paired, your Hermes server sends a notification when a reply finishes, when the assistant waits for you (to approve a command, answer a question, or enter a password or a secret), when a turn fails, and when a task it handed off comes back. Your server encrypts each one with a key that only it and your iPhone hold, and sends it to a relay operated by Goosehouse LLC (redde-push.goosehouse.org, hosted on Cloudflare). The relay hands it to Apple's push notification service, which delivers it, and your iPhone decrypts it.

What the relay holds for each pairing:

- your iPhone's push token: the address Apple issues so that notifications for Redde can reach that device;
- a one-way hash of a random secret, which lets your server, and nobody else, send to that token;
- whether the token belongs to a development or an App Store build, and when the iPhone last checked in;
- if you turn on Calls from Agents, a second token for the same device, the address Apple issues for incoming calls to Redde, which the relay uses only to deliver an agent's call. Turning calls off has the relay delete it.

What passes through and is not kept: the encrypted notifications. Inside the encryption is a short note saying what happened, the conversation's id and title, and up to the first 500 characters of the reply, or the command or question that is waiting. The relay has no key and cannot read any of it, and neither can Apple. The text Apple is given to display is always the same placeholder, which your iPhone replaces once it has decrypted the note. While you pair by scanning a code, the relay also holds your iPhone's half of the key exchange (a public key and an encrypted answer for your server) for at most ten minutes.

The relay has no accounts and nothing that says who you are: no name, no email address, no contact details. Like any internet service, it and its host see the network address a request comes from, and the host keeps routine request logs (the time, the path and the result, never a notification's content) for a few days. We use what the relay holds only to deliver your notifications. We do not combine it with anything else, share it, or sell it.

A pairing is deleted from the relay when you remove it in Redde (swipe it away under Notify when Redde is closed), when Apple reports that the token is no longer valid, for example after the app is deleted, or after 120 days in which the iPhone has not checked in. Your Hermes server keeps its own record of the pairing until it next tries to send; `hermes redde-push remove` deletes it there.

The Hermes server needs a small plugin for this. You can install it there yourself, or, when Redde is signed in to that server's Dashboard, have Redde ask the server to install it: the server then downloads the plugin from our public repository on GitHub. Redde passes the request to your own server and downloads nothing itself.

Notifications that Redde posts itself while it is running do not involve the relay.

### Calls from agents

If you turn on Calls from Agents (Settings › Notifications), an agent you allow can ring your iPhone like a phone call. The call travels as a notification does: your Hermes server encrypts a short note (which agent is calling, what it will say first, the conversation it called from) with the pairing's key and sends it through the relay, which hands it to Apple to deliver as an incoming call to Redde. The relay and Apple cannot read it. Redde shows the call with Apple's CallKit, which iOS uses for every app's calls; Redde asks iOS not to add these calls to the Phone app's list of recent calls. When you answer, the conversation is voice mode in that agent's chat, and what you say goes to your own server as in any other conversation. A call you don't answer is shown as a notification that Redde posts on your iPhone. Which agents may call is kept by Redde on this iPhone and told to your own server; it is not synced to your other devices.

## Speech

Voice input is transcribed on your device using Apple's on-device speech recognition, in voice mode and when you dictate into the message field. Audio never leaves the device, unless you start a live voice call (below). Only the resulting text is sent, and only to your configured server. Where a reply can be talked over (Settings → Voice → Talk over replies: with headphones, unless you change it), the microphone stays open in voice mode while the reply is read aloud, so that Redde can notice you starting to speak. That audio is handled the same way and nothing is recorded. The on-device voice used to read replies aloud also runs entirely on the device. If you enable a server-side text-to-speech voice in Settings, reply text is sent to the TTS server address you configure so it can return audio. If you choose ElevenLabs to read replies (Settings → Voice), the text of each reply read aloud goes from your device to ElevenLabs (api.elevenlabs.io) on your own ElevenLabs key, and ElevenLabs bills your account for it; nothing else is sent, and nothing goes to Goosehouse LLC.

### Wake phrases (optional, off by default)

If you turn on wake phrases (Settings → Voice → Wake Phrase), the microphone stays on while Redde is open on your screen or on your car's, with the system's indicator showing, so that Redde can hear an agent's phrase, such as "Hey Sol". Nothing is transcribed until the sound says someone is talking. Then a few seconds are transcribed on the device to look for a phrase, and let go of at once when there isn't one. Nothing is recorded or sent anywhere. What you say after a phrase is sent to your configured server, as anything said in voice mode is. Wake phrases stop while Redde isn't on screen and while something else uses the microphone.

## Live voice calls (optional, off by default)

If you choose a live voice under Settings → Voice → Voice mode, or for one bot in its voice settings, a voice conversation is held by that service's voice model instead of on your device: GPT-Live (OpenAI), Gemini Live (Google), Grok Voice (xAI), or ElevenLabs. While a call is open (from when you start it until you hang up, say a stop phrase, leave voice mode, or it hangs up after the quiet you set), what your microphone hears is streamed to that service, and its voice is streamed back. When a call starts, the latest messages of the conversation (24 at most) and the names you call your bots by are given to the service, so that the voice knows what you were talking about and whom you may ask for. Requests the voice hands to your assistant go to your configured server as messages, as typed ones do, together with the recent spoken exchange, and your assistant's answers are sent to the service for the voice to say. If you also turn on Group Chats as Calls, a group chat's voice is such a call: the group's latest messages (24 at most) and its members' names are given to the service, what you say goes to the group on your server, and each member's reply is sent to the service to be said in that member's voice.

Calls are made with an API key you enter for that service, kept in the iOS Keychain. Each call goes directly between your device and the service and does not pass through Goosehouse LLC. The service handles it under its own terms and privacy policy, and bills the key's account for it. Redde also uses that key to list the service's voices and to play one before you pick it. For ElevenLabs, the first call creates one agent in your ElevenLabs account, named "Redde voice", with the one tool it hands requests over with; each call then tells that agent whom it speaks as and in which voice. Nothing in this section happens unless you choose a live voice.

## Siri and Shortcuts

Redde offers Siri phrases and Shortcuts actions. When you use them, Apple's Siri processes your spoken command according to Apple's privacy policy, then hands control to Redde. Redde does not receive audio from Siri. Questions typed or dictated into the "Ask Redde a Question" shortcut action, and notes given to "Take a Note in Redde", are sent only to your configured server; a note taken while that server can't be reached is kept on the device until it can be sent, and then removed. If you use Hermes profiles, Redde tells Siri and Shortcuts the names of the profiles it knows of, so that a phrase such as "Ask Work in Redde" is understood; Apple handles those names as it does any app's Siri phrases.

### Siri with Apple Intelligence (optional, off by default)

On iOS 27 and later you can turn on "Let Siri use Redde" in Settings. With it on, you can ask Siri to message your assistant in your own words, have Siri read replies aloud, and find Redde conversations in Siri and Spotlight. To do this, Apple Intelligence processes what you say to Siri, including the message itself, and Redde makes its recent conversations (titles, and message text unless the app lock is on) available to Siri and to the on-device Spotlight index. That processing is Apple's, under Apple's privacy policy. Redde still sends your messages only to your configured server, and none of it reaches Goosehouse LLC. Turning the setting off stops Siri's access and removes Redde's entries from Spotlight.

## Data stored on your device

- **Credentials** (server API keys, passwords, the tokens of a browser sign-in, any custom headers you add for a server, and the keys of live voice services) are stored in the iOS Keychain, and never leave the device except in requests to the servers and services they belong to, and, if you turn on Sync with iCloud, to your other devices through iCloud Keychain, which is end-to-end encrypted. Browser sign-ins always stay on the device.
- **Notification pairings**, if you make any: the key shared with your Hermes server and what identifies the pairing at the relay, in the iOS Keychain on this device.
- **Conversation history**, **attachments** and **drafts** (what you have typed and not sent) are stored in the app's private container with iOS data protection. They are not synced or backed up by Redde, though they are included in your own iCloud or computer backups of the device like any app data.
- **Settings** are stored in the app's preferences on the device. If you turn on Sync with iCloud, your servers and settings are also kept in your iCloud account, for your other iPhones, iPads and Macs signed in to it; which server and profile each device is on, App Lock, Siri, Phone tools, wake phrases being on, and notifications stay on each device.
- **Shared items** sent to Redde from other apps via the share sheet are stored briefly in the app's private container until Redde opens and moves them into the composer.
- **Files from your server** that you open in Settings → Files are downloaded to a temporary folder so they can be shown, and removed the next time you open the file browser. Files you upload from there go only to your server.
- **What the widgets show** (the last reply, a command or question that is waiting for you, and how full the model's context is) is kept in a container the app shares with its widgets, on the device. With the app lock on, the widgets leave out commands, questions and titles.

You can delete conversations and attachments inside the app, remove credentials in Settings, or delete all data by deleting the app.

## Signing in through a browser

If your Hermes Dashboard signs people in with Google or another identity provider, Redde opens that Dashboard's own sign-in page in a system sign-in sheet. Your password goes to that page and its provider, never to Redde. What comes back is a pair of tokens issued by your Dashboard, which Redde keeps in the Keychain and sends only to that Dashboard. Goosehouse LLC is not involved.

## Apple Watch

The Apple Watch app gets your server's address and key from Redde on your iPhone and then talks to that server itself, or asks through the iPhone. The key is kept in the watch's Keychain. Questions are dictated with the watch's own dictation. When it talks to the server itself, the watch can list your recent conversations there and carry one on. The "Ask Redde" complication for a watch face only opens the app; it holds no data. Nothing goes anywhere else.

## Photos, camera, files, microphone, head movement, and Face ID

- Redde uses the system photo picker and file picker, which give the app access only to the items you select. A video that is too large to send is made smaller on the device first.
- The camera is used only when you choose Camera from the + menu, switch the camera on in voice mode, or Scan a setup code in setup. In voice mode it is on only while its button is, with the system's indicator showing, and one picture is taken for each question you ask meanwhile; nothing else it sees is kept or sent. A photo you take becomes an attachment in your message: it is kept with that conversation like any attachment and sent only to your server, and it is not saved to your photo library. Scanning a setup code reads the QR code on the device; no picture is kept or sent.
- The microphone is used only while you are talking with the app (voice mode, including while a reply that can be talked over is read aloud, and dictation into the message field) and, if you turn on wake phrases, while Redde is open, with the system's indicator showing, and only for on-device transcription, or, during a live voice call you start, streamed to the service you chose as described above.
- If you turn on Phone tools, your assistant can ask Redde for the areas you switch on: calendar events, reminders, contacts, photos (when they were taken, what they show, and a photo it asks to look at), the files in Redde's own folder, and the alarms and timers Redde itself has set (it can set and cancel those once you confirm; it cannot see the Clock app's). With calls and messages on, your assistant can ask Redde to start a call, which iOS asks you to confirm, and to write a message, which opens in Messages for you to send or discard: Redde sends nothing by itself, and your assistant does not hear the call or see your messages. It learns whom you asked it to call or write to, and whether you sent the message. With the widget area on, your assistant can write a few lines on Redde's own widget; that sends nothing from your iPhone. If Redde is closed and your iPhone is paired for notifications, what it wrote arrives the way notifications do, encrypted between your server and your iPhone. To find a photo by what it shows, Redde looks at your pictures on the device while it is open, with Apple's on-device image recognition, and keeps what it made out (the things in each picture, and text in screenshots, documents and signs) in a file on the device that is not backed up and is deleted when you turn Photos off. Your assistant is told what was made out only for the photos that match what it asked for. What it asks for is read on the device and sent to the server you connect to, and nowhere else, at the moment it asks. Each area is off until you turn it on, you can have Redde ask you every time, and adding, changing or deleting anything is always put to you first. A list of what was asked for is kept on the device.
- If you turn on "Nod or shake to answer", Redde reads head movement from your AirPods while a request from your assistant waits for your answer in voice mode, to tell a nod from a shake. It is read on the device, at no other time, and is not stored or sent anywhere.
- If you enable the app lock, or ask for your passwords to be included in a setup code for another device, Face ID or Touch ID is evaluated by iOS. Redde never receives biometric data.

## Setup links

A setup link (`https://redde.goosehouse.org/connect#…`) carries a server's connection in the part of the address after the `#`. Browsers do not send that part to a website, so it never reaches redde.goosehouse.org. With Redde installed, iOS opens the link in the app without loading the page at all. Without it, the page reads the link on your device only to show what it carries and hand it to the app; it sends nothing anywhere and collects nothing.

## Live Activities, widgets and Controls

Redde can show the progress of a reply in a Live Activity on the Lock Screen and in the Dynamic Island, and offers widgets and Control Center buttons. These display information already on your device and send nothing anywhere.

## Children

Redde is not directed at children under 13, and has no accounts and no personal details of anyone.

## Changes

If this policy changes, the new version will be posted at this address with an updated effective date. The October 2026 version added the optional notification relay; before it, Goosehouse LLC ran no service for Redde at all. The October 25, 2026 version added live voice calls and wake phrases, and says what Sync with iCloud sends to your other devices. The October 26, 2026 version added the plugin catalog that Find Plugins downloads, ElevenLabs as a voice that reads replies, group chats as live calls, and calls from agents.

## Contact

Questions about this policy: hello@goosehouse.org
