# Redde plugin 1.31.0 — GitHub release draft

Title: **Redde plugin 1.31.0**. Tag: `redde-push-1.31.0`, on the commit that carries
`version: 1.31.0` in `companion/hermes-plugin/redde-push/plugin.yaml`. The last release page is
`redde-push-1.27.0`; this one covers 1.28.0 to 1.31.0. The full list is in that folder's
`CHANGELOG.md`. Everything below the line is the release's text.

---

The Hermes plugin that goes with Redde 2.6: more piles in the Inbox and piles of your own, Maps
as a phone tool, a deal meter on price cards, and approvals that are the same on every device.

Update it from Redde's Settings › Redde Plugin, or on your Hermes with `hermes plugins install`
and `--force`. If you have several profiles, update each one's copy, and restart both the gateway
and `hermes serve` afterwards.

## What's new

- **More piles in the Inbox (1.31).** Mail sorts into seven piles: Important, Needs Reply, FYI,
  Receipts, Notifications, Promotions and Newsletters. Receipts and offers used to land in
  Newsletters, and sign-in codes and app notices in FYI. Mail already sorted is moved into the new
  piles once, by its headers; anything you moved yourself stays where you put it.
- **Piles of your own (1.31).** Name one and say what goes in it in Redde's Settings › Email ›
  Piles, or ask your agent. New mail goes in it when it fits, even mail sorted by its headers.
  Up to eight. A rule can put mail in a pile (`do: "group"`), and so can the agent with
  `redde_mail` `group`. With Show Sorting in Gmail on, each pile is a `Redde/…` label.
- **Maps on the phone (1.30).** With Maps turned on in Redde (Settings › Phone Tools), the agent
  finds places near the iPhone or near a place it names (`phone_maps_search`), works out how long
  the way takes with the traffic now (`phone_maps_directions`), and opens Apple Maps ready to go
  (`phone_maps_open`). The agent hears places, times and distances, never the phone's coordinates.
- **A deal meter (1.29).** A purchase card may carry what the pick usually sells for
  (`usual_price`, from a price history or a list price the agent found, never a guess), and Redde
  shows how good a deal it is. The card's Watch price button asks the agent to keep an eye on it.
- **Waiting on you, on every device (1.28).** What the bots wait on you for is kept in each
  profile's home (`redde-waiting.json`) and read with `/redde-push waiting`, over the Dashboard or
  the Hermes API, so an approval answered on one device is gone from all of them.

## Good to know

- Redde from before 1.31 is shown the four piles it knows, the new ones folded into Newsletters
  and FYI, so no mail goes missing. Editing rules in an older Redde drops a rule that puts mail in
  a pile: update Redde to 2.6 first.
