// The setup-link page: reads the connection from the address's fragment (the part after "#",
// which a browser never sends to a server), shows what it carries, and hands it to the app
// through the app's own link, redde://connect?…. It sends nothing anywhere; the page's content
// security policy forbids it as well.
(function () {
  "use strict";
  var raw = location.hash.replace(/^#/, "");
  // Out of the address bar (and so out of shared or synced tabs) at once; this script keeps it.
  if (raw && history.replaceState) history.replaceState(null, "", location.pathname);

  var fields = Object.create(null);
  var headers = [];   // names only: a header's value is a secret, like a key
  raw.split("&").forEach(function (pair) {
    var at = pair.indexOf("=");
    if (at < 1) return;
    try {
      var name = decodeURIComponent(pair.slice(0, at)).toLowerCase();
      var value = decodeURIComponent(pair.slice(at + 1)).trim();
      if (name === "header") {   // the one parameter that may repeat: "Name: value"
        var colon = value.indexOf(":");
        if (colon > 0 && value.slice(colon + 1).trim() && headers.length < 8) headers.push(value.slice(0, colon).trim());
        return;
      }
      if (value && !(name in fields)) fields[name] = value;   // the first of a repeat counts, as in the app
    } catch (e) { /* a badly escaped value is no value */ }
  });
  if (!fields.dashboard && !fields.api && !fields["model-url"]) return;   // not a setup link: the page on its own

  // Text only, never markup: the link is somebody else's input.
  var summary = document.getElementById("summary");
  function row(title, value, note) {
    if (!value) return;
    var div = document.createElement("div"), dt = document.createElement("dt"), dd = document.createElement("dd");
    dt.textContent = title;
    dd.textContent = value;
    if (note) {
      var small = document.createElement("small");
      small.textContent = note;
      dd.appendChild(small);
    }
    div.appendChild(dt);
    div.appendChild(dd);
    summary.appendChild(div);
  }
  function notes(list) { return list.filter(Boolean).join(" · "); }
  row("Name", fields.name);
  row("Hermes Dashboard", fields.dashboard,
      notes([fields.user && "user " + fields.user, fields.password ? "password included" : "no password"]));
  row("Hermes API", fields.api, fields.key || fields["profile-key"] ? "key included" : "no key");
  row("Profile", fields.profile);
  if (fields.dashboard || fields.api) row(headers.length === 1 ? "Custom header" : "Custom headers", headers.join(", "), headers.length ? "value included" : "");
  row("Model endpoint", fields["model-url"], notes([fields.model, fields["model-key"] && "key included"]));

  document.getElementById("open").href = "redde://connect?" + raw;
  document.getElementById("bare").hidden = true;
  document.getElementById("code").hidden = false;
})();
