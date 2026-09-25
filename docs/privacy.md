---
title: Redde Privacy Policy
---

# Redde Privacy Policy

**Effective date:** September 10, 2026
**Publisher:** Goosehouse LLC

Redde is a voice and chat client for an AI assistant that you run yourself. This policy explains what the app does with your information. The short version: Redde collects nothing, and the only place your data goes is the server you configure.

## What Redde does not do

- Redde has no analytics, crash reporting, advertising, or tracking of any kind.
- Redde contains no third-party SDKs.
- Goosehouse LLC operates no servers for Redde and receives no data from the app. We cannot see your conversations, your credentials, or your usage.
- Redde does not sell, share, or transfer personal information to anyone.

## Where your data goes

Redde sends messages, attachments, and voice transcripts only to the server address you enter in the app's setup. That server is one you control or choose: typically a self-hosted Hermes agent or an OpenAI-compatible model server on your own network. What that server does with your data is governed by your own configuration and, if you point Redde at a third-party hosted provider, by that provider's privacy policy. Redde itself adds no intermediary.

Connections use HTTPS when the address you enter provides it. Because self-hosted servers on private networks often lack public certificates, Redde also allows plain HTTP connections to addresses you choose.

## Speech

Voice input is transcribed on your device using Apple's on-device speech recognition. Audio never leaves the device. Only the resulting text is sent, and only to your configured server. The on-device voice used to read replies aloud also runs entirely on the device. If you enable a server-side text-to-speech voice in Settings, reply text is sent to the TTS server address you configure so it can return audio.

## Siri and Shortcuts

Redde offers Siri phrases and Shortcuts actions. When you use them, Apple's Siri processes your spoken command according to Apple's privacy policy, then hands control to Redde. Redde does not receive audio from Siri. Questions typed or dictated into the "Ask Redde a Question" shortcut action are sent only to your configured server.

### Siri with Apple Intelligence (optional, off by default)

On iOS 27 and later you can turn on "Let Siri use Redde" in Settings. With it on, you can ask Siri to message your assistant in your own words, have Siri read replies aloud, and find Redde conversations in Siri and Spotlight. To do this, Apple Intelligence processes what you say to Siri, including the message itself, and Redde makes its recent conversations (titles, and message text unless the app lock is on) available to Siri and to the on-device Spotlight index. That processing is Apple's, under Apple's privacy policy. Redde still sends your messages only to your configured server, and Goosehouse LLC still receives nothing. Turning the setting off stops Siri's access and removes Redde's entries from Spotlight.

## Data stored on your device

- **Credentials** (server API keys and passwords) are stored in the iOS Keychain, restricted to this device, and never leave it except in requests to the servers they belong to.
- **Conversation history** and **attachments** are stored in the app's private container with iOS data protection. They are not synced or backed up by Redde, though they are included in your own iCloud or computer backups of the device like any app data.
- **Settings** are stored in the app's preferences on the device.
- **Shared items** sent to Redde from other apps via the share sheet are stored briefly in the app's private container until Redde opens and moves them into the composer.

You can delete conversations and attachments inside the app, remove credentials in Settings, or delete all data by deleting the app.

## Photos, files, microphone, and Face ID

- Redde uses the system photo picker and file picker, which give the app access only to the items you select.
- The microphone is used only while you are actively speaking to the app, with the on-screen indicator, and only for on-device transcription.
- If you enable the app lock, Face ID or Touch ID is evaluated by iOS. Redde never receives biometric data.

## Live Activities and Controls

Redde can show the progress of a reply in a Live Activity on the Lock Screen and in the Dynamic Island, and offers Control Center buttons. These display information already on your device and send nothing anywhere.

## Children

Redde is not directed at children under 13 and collects no information from anyone.

## Changes

If this policy changes, the new version will be posted at this address with an updated effective date. Since the app collects no data, changes are expected to be clarifications.

## Contact

Questions about this policy: hello@goosehouse.org
