#if os(iOS)
import CoreLocation
import MapKit
import SwiftUI

/// Settings → Agent → Places (`Places`).
struct PlacesView: View {
    @State private var places = Places.shared
    @State private var editing: WatchedPlace?

    var body: some View {
        List {
            Section {
                if places.places.isEmpty {
                    Text("Set a place, Home or Work or the gym, and what your agent should do when you arrive or leave: \u{201C}I'm home: turn on the hall light\u{201D}. Your iPhone notices on its own, even with Redde closed.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(places.places) { place in
                    Button { editing = place } label: { row(place) }
                        .buttonStyle(.plain)
                        .swipeActions { Button("Delete", systemImage: "trash", role: .destructive) { places.remove(place) } }
                }
                if places.places.count < Places.most {
                    Button("Add Place", systemImage: "plus") {
                        editing = WatchedPlace(name: "", latitude: 0, longitude: 0)
                    }
                }
            } footer: {
                Text("Where you are stays on your iPhone: your server hears only \u{201C}arrived at Home\u{201D}, with your message. The answer comes as a notification.")
            }
            if !places.places.isEmpty, !places.allowedAlways {
                Section {
                    Button("Allow Location Always") {
                        if places.authorization == .denied || places.authorization == .restricted {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        } else { places.askPermission() }
                    }
                } footer: {
                    Text("To notice arrivals with Redde closed, iOS needs Location set to Always for Redde.")
                }
            }
        }
        .navigationTitle(String(localized: "places.title", defaultValue: "Places", comment: "Settings: places the iPhone notices arriving at or leaving"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing) { place in PlaceEditor(place: place) }
    }

    private func row(_ place: WatchedPlace) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(place.name).font(.body.weight(.semibold))
            if let arrive = place.arrive { line("arrow.down.right.circle", String(localized: "Arrive: \(arrive.message)")) }
            if let leave = place.leave { line("arrow.up.right.circle", String(localized: "Leave: \(leave.message)")) }
        }
        .contentShape(.rect)
    }

    private func line(_ symbol: String, _ text: String) -> some View {
        Label(text, systemImage: symbol).font(.caption).foregroundStyle(.secondary).lineLimit(2)
    }
}

/// A place: where (where the phone is, or an address), how near counts, and what to say on
/// arriving and on leaving, to whom.
struct PlaceEditor: View {
    @State var place: WatchedPlace
    @State private var address = ""
    @State private var finding = false
    @State private var problem: String?
    @State private var arriveOn = false
    @State private var leaveOn = false
    @State private var arrive = PlaceAction(profile: "default", message: "")
    @State private var leave = PlaceAction(profile: "default", message: "")
    @State private var places = Places.shared
    @Environment(\.dismiss) private var dismiss

    private var located: Bool { place.latitude != 0 || place.longitude != 0 }

    /// The main agent and, where there are bots, each of them.
    private var agents: [(profile: String, name: String)] {
        let settings = Settings.shared
        var out: [(String, String)] = [("default", settings.headerTitle)]
        if BotDirectory.available(), BotDirectory.shared.key == settings.connectionKey {
            for bot in BotDirectory.shared.roster?.listed ?? [] where !bot.isDefault { out.append((bot.name, bot.label(mainName: settings.headerTitle))) }
        }
        return out
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name (Home, Work, the gym)", text: $place.name)
                }
                Section {
                    if located {
                        Map(initialPosition: .region(MKCoordinateRegion(center: coordinate, latitudinalMeters: place.radius * 4, longitudinalMeters: place.radius * 4))) {
                            MapCircle(center: coordinate, radius: place.radius).foregroundStyle(.tint.opacity(0.25))
                            Marker(place.name.isEmpty ? String(localized: "Here") : place.name, coordinate: coordinate)
                        }
                        .frame(height: 160)
                        .id("\(place.latitude),\(place.longitude),\(place.radius)")
                        .listRowInsets(EdgeInsets())
                    }
                    Button("Use Where I Am", systemImage: "location") { Task { await useHere() } }
                        .disabled(finding)
                    HStack {
                        TextField("Or an address", text: $address).submitLabel(.search).onSubmit { Task { await find() } }
                        if finding { ProgressView() }
                    }
                    Picker("How Near", selection: $place.radius) {
                        Text("Close (100 m)").tag(100.0)
                        Text("Nearby (200 m)").tag(200.0)
                        Text("Around (500 m)").tag(500.0)
                    }
                } header: {
                    Text("Where")
                }
                action(String(localized: "When I Arrive"), on: $arriveOn, action: $arrive, example: String(localized: "I'm home: turn on the hall light."))
                action(String(localized: "When I Leave"), on: $leaveOn, action: $leave, example: String(localized: "I've left: lock up and turn the heating down."))
                if let problem { Section { Text(problem).foregroundStyle(.red).font(.footnote) } }
            }
            .navigationTitle(place.name.isEmpty ? String(localized: "New Place") : place.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(place.name.trimmingCharacters(in: .whitespaces).isEmpty || !located || (!arriveOn && !leaveOn))
                }
            }
            .onAppear {
                if let a = place.arrive { arrive = a; arriveOn = true }
                if let l = place.leave { leave = l; leaveOn = true }
                if !located, places.authorization == .notDetermined { places.askPermission() }
            }
        }
    }

    private var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude) }

    private func action(_ title: String, on: Binding<Bool>, action: Binding<PlaceAction>, example: String) -> some View {
        Section {
            Toggle(title, isOn: on)
            if on.wrappedValue {
                Picker("Tell", selection: action.profile) {
                    ForEach(agents, id: \.profile) { Text($0.name).tag($0.profile) }
                }
                TextField(example, text: action.message, axis: .vertical).lineLimit(2 ... 5)
            }
        }
    }

    private func useHere() async {
        finding = true
        defer { finding = false }
        guard let here = await places.here() else {
            problem = String(localized: "Redde couldn't tell where you are. Allow Location for Redde in Settings, or type an address.")
            return
        }
        place.latitude = here.coordinate.latitude
        place.longitude = here.coordinate.longitude
        problem = nil
    }

    private func find() async {
        let query = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        finding = true
        defer { finding = false }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        guard let item = try? await MKLocalSearch(request: request).start().mapItems.first else {
            problem = String(localized: "That address wasn't found.")
            return
        }
        place.latitude = item.location.coordinate.latitude
        place.longitude = item.location.coordinate.longitude
        if place.name.isEmpty, let name = item.name { place.name = name }
        problem = nil
    }

    private func save() {
        place.name = place.name.trimmingCharacters(in: .whitespaces)
        place.arrive = arriveOn ? arrive : nil
        place.leave = leaveOn ? leave : nil
        places.save(place)
        places.askPermission()   // Always, for when Redde is closed
        dismiss()
    }
}
#endif
