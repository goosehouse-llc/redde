import Foundation
import Testing
@testable import Echo

/// Hermes plugins (`PluginsView`): the catalog as Nous publishes it, searched on the phone, and what
/// the Dashboard's `plugins.manage` answers. Installing for real is `lab.sh plugins`.
struct PluginCatalogTests {
    private static let catalog = Data("""
    {"generated_at": "2026-10-26T00:00:00Z",
     "entries": [
      {"name": "elevenlabs-sound-effects", "repo": "https://github.com/NousResearch/hermes-official-plugins", "sha": "e4e4",
       "subdir": "elevenlabs-sound-effects", "title": "ElevenLabs Sound Effects",
       "description": "Sound effects from a description. Disclosure: uses your ElevenLabs API key; every call is billed.",
       "maintainer": "NousResearch", "tier": "official", "category": "tools", "requires_hermes": ">=0.22.0", "version": "1.2.0",
       "capabilities": {"provides_tools": ["elevenlabs_sound_effect"], "provides_hooks": [], "provides_middleware": [], "requires_env": ["ELEVENLABS_API_KEY"]},
       "image": "http://example.com/plain.png"},
      {"name": "spotify", "repo": "https://github.com/NousResearch/hermes-official-plugins", "sha": "aaaa", "description": "Spotify playback, search and playlists.",
       "maintainer": "NousResearch", "tier": "official", "category": "tools", "platforms": ["linux", "macos"]},
      {"name": "sound-board", "repo": "https://github.com/someone/sound-board", "sha": "bbbb", "description": "A spotify-free sound board.",
       "maintainer": "someone", "category": "tools"},
      {"name": "or-picker", "repo": "https://github.com/someone/or-picker", "sha": "cccc", "description": "Gone.", "maintainer": "someone", "tier": "community"},
      {"name": "no-repo", "description": "Broken entry."}
     ],
     "removed": [{"name": "or-picker", "reason": "Folded into openrouter-picker."}]}
    """.utf8)

    @Test func theCatalogIsReadAsNousPublishesIt() throws {
        let catalog = try #require(PluginCatalog.parse(Self.catalog))
        #expect(catalog.plugins.map(\.name) == ["elevenlabs-sound-effects", "spotify", "sound-board"], "a removed entry and a broken one are dropped")
        let sounds = catalog.plugins[0]
        #expect(sounds.title == "ElevenLabs Sound Effects" && sounds.tier == .official && sounds.version == "1.2.0")
        #expect(sounds.tools == ["elevenlabs_sound_effect"] && sounds.keys == ["ELEVENLABS_API_KEY"])
        #expect(sounds.summary == "Sound effects from a description.")
        #expect(sounds.disclosure == "uses your ElevenLabs API key; every call is billed.")
        #expect(sounds.image == nil, "only an https picture")
        #expect(catalog.plugins[1].title == "Spotify" && catalog.plugins[1].disclosure == nil && catalog.plugins[1].platforms == ["linux", "macos"])
        #expect(catalog.plugins[2].tier == .community, "no tier: anyone's")
        #expect(CatalogPlugin.title(for: "hermes-memory_wiki") == "Hermes Memory Wiki")
    }

    @Test func aPluginSaysWhichHermesItNeeds() throws {
        let sounds = try #require(PluginCatalog.parse(Self.catalog)?.plugins.first)
        #expect(sounds.runs(onHermes: "0.22.2") == true)
        #expect(sounds.runs(onHermes: "0.21.5") == false)
        #expect(sounds.runs(onHermes: "0.0.0") == nil, "a build from source: Hermes decides")
        #expect(HermesVersion.meets(">=0.21.6,<0.23", version: "0.22.2") == true)
        #expect(HermesVersion.meets(">=0.21.6,<0.23", version: "0.23.0") == false)
        #expect(HermesVersion.meets("~=1.0", version: "0.22.2") == nil, "a clause it can't read")
        #expect(HermesVersion.meets(">=0.22", version: "0.22.0") == true)
    }

    @Test func searchingFindsByNameFirstAndKeepsToTheTiersAsked() throws {
        let catalog = try #require(PluginCatalog.parse(Self.catalog))
        let checked: Set<CatalogPlugin.Tier> = [.official, .verified]
        #expect(catalog.search("", tiers: checked).map(\.name) == ["elevenlabs-sound-effects", "spotify"])
        #expect(catalog.search("spotify", tiers: Set(CatalogPlugin.Tier.allCases)).map(\.name) == ["spotify", "sound-board"],
                "the name before a description that mentions it")
        #expect(catalog.search("spotify", tiers: checked).map(\.name) == ["spotify"], "community left out")
        #expect(catalog.search("sound billed", tiers: checked).map(\.name) == ["elevenlabs-sound-effects"], "every word, anywhere")
        #expect(catalog.search("sound piano", tiers: checked).isEmpty)
        #expect(catalog.search("", tiers: Set(CatalogPlugin.Tier.allCases), category: "general").isEmpty)
        #expect(catalog.categories.first == "tools")
    }

    @Test func anInstalledPluginIsReadAsTheDashboardListsIt() throws {
        let row = try JSONValue.parse(Data("""
        {"name": "spotify", "key": "spotify", "version": "1.1.0", "description": "Spotify.", "source": "user", "status": "disabled",
         "portable": true, "install_dir": "/x", "has_desktop_half": false,
         "servers": [{"name": "spotify-mcp", "state": "connected", "sentence": ""}],
         "catalog_name": "spotify", "catalog_tier": "official", "update_available": true,
         "settings_schema": [
          {"key": "market", "type": "enum", "label": "Market", "description": "", "required": false, "value": null, "default": "US", "choices": ["US", "PT"]},
          {"key": "token", "type": "secret", "label": "Token", "description": "", "required": true, "env": "SPOTIFY_TOKEN", "has_value": false}]}
        """.utf8))
        let plugin = try #require(InstalledPlugin(row))
        #expect(!plugin.enabled && !plugin.bundled && plugin.updateAvailable && plugin.catalogTier == .official)
        #expect(plugin.servers.map(\.name) == ["spotify-mcp"])
        #expect(plugin.settings.map(\.kind) == [.enum, .secret])
        #expect(plugin.settings[0].value == .string("US"), "the default where nothing is set")
        #expect(plugin.settings[1].env == "SPOTIFY_TOKEN" && !plugin.settings[1].isSet)
        let bundled = try #require(InstalledPlugin(.object(["name": .string("memory"), "source": .string("bundled"), "status": .string("enabled")])))
        #expect(bundled.enabled && bundled.bundled && bundled.key == "memory")
    }

    @Test func anInstallSaysWhatWorksNowAndWhatLater() throws {
        let result = try JSONValue.parse(Data("""
        {"ok": true, "plugin_name": "spotify", "enabled": true, "missing_env": ["SPOTIFY_TOKEN"], "known_issues": ["Needs Premium."],
         "warnings": [], "gateway_reloaded": true, "restart_required": true,
         "activation": {"name": "spotify", "key": "spotify",
           "activated_now": {"gateway_commands": ["spotify"]},
           "live_now": {"mcp_servers": [{"name": "spotify-mcp", "connected": true, "tools": ["play"]},
                                        {"name": "lyrics", "connected": false, "error": "no key"}],
                        "skills": [{"name": "spotify:dj"}]},
           "deferred": {"tools": ["spotify_search"]}}}
        """.utf8))
        let outcome = PluginOutcome(result, name: "fallback")
        #expect(outcome.name == "spotify")
        #expect(outcome.liveNow == ["spotify-mcp: play", "lyrics didn't connect: no key", "the spotify:dj skill", "gateway commands: spotify"])
        #expect(outcome.nextChat == ["tools: spotify_search"])
        #expect(!outcome.restartRequired, "a gateway that took it up needs no restart")
        #expect(outcome.missingKeys == ["SPOTIFY_TOKEN"] && outcome.notes == ["Needs Premium."])
    }
}
