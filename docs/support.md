---
title: Redde Support
---

# Redde Support

Redde is a voice and chat client for a self-hosted AI assistant.

- **Setup:** open the app and follow the setup sheet, or go to Settings → Connection → "Set up connection…". "Test connection" tells you whether the server and credentials work before you send anything.
- **Setup codes:** instead of typing, scan a setup code or paste a setup link in the setup sheet. Redde shows what the code sets and saves nothing until you agree. To set up a second device, open Settings → Connection → "Set up another device…" on the first and scan the code it shows; turn on "Include passwords and keys" to carry those across too. A code with passwords in it is as good as the passwords, so show it only to your own devices.
- **Siri:** say "Hey Siri, ask Redde". For a custom phrase, create a Shortcut containing Redde's "Ask Redde" action and name it whatever you want to say.
- **CarPlay:** connect your iPhone to CarPlay and open Redde on the car's screen. Tap "Ask Redde" for one question or "Talk with Redde" for a hands-free conversation; both carry on the conversation your iPhone has open. "New Chat" starts another, and "Recent Chats" lists your conversations to pick one. The voice card has Mute and End. If Redde isn't on the car's screen, turn it on in Settings → General → CarPlay → your car.
- **Models:** tap the model name under the conversation title (or type /model) to switch models mid-conversation. The choice sticks for that conversation.
- **Spoken prefixes:** start a voice or Siri message with a word of your choice and Redde can drop a text prefix in front, switch the conversation to a model you chose, or both. Say "Opus, review this diff" and the conversation moves to Opus before the message goes. The switch sticks until you pick another model. Set it up in Settings → Voice → Spoken prefixes: the word, the ways it tends to be misheard, the prefix, and the model from your server's list. Off until you add a rule, spoken messages only; anything you type stays exactly as typed.
- **Notifications when Redde is closed:** iOS closes Redde in the background after a few minutes. To be told about replies, approvals and questions anyway, pair your Hermes: Settings → Voice → Notify when Redde is closed. Your Hermes needs the redde-push plugin first; the screen shows the command (`hermes plugins install goosehouse-llc/redde/companion/hermes-plugin/redde-push --enable`, with `--force` on the end to update one that is already there, then restart Hermes). Signed in to the Hermes Dashboard, tap "Pair with" your server; otherwise run `hermes redde-push pair` on the Hermes machine and scan the code it shows. Answering a question from its notification needs Hermes 0.21.3 or later.
- **Talk over a reply:** in voice mode, start speaking while Redde is answering and it stops to listen. It is on with headphones. Settings → Voice → Talk over replies adds the phone's speaker, where replies then play at call volume, or turns it off. "Interrupt with" can make it only the word "stop", for a room where other people are talking.
- **Signing in with Google or another provider:** if your Hermes Dashboard has no password login, use Settings → Connection details → Sign in with a browser. It needs Hermes 0.21 or later.
- **Behind a reverse proxy:** if the proxy in front of your Hermes asks for a header of its own, add it under Settings → Connection details → Custom headers.
- **Voice tones:** a rising tone means the mic is open; a falling tone means it stopped listening. They follow the volume rocker, not the silent switch.
- **Privacy:** see the [privacy policy](privacy.html). Your conversations go only to the server you configure. The one optional exception to "nothing leaves your setup" is notifications when Redde is closed, which pass through our relay encrypted.
- **Questions or problems:** email hello@goosehouse.org, or open an issue on the project's GitHub repository.
