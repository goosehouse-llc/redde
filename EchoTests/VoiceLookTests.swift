import AVFoundation
import CoreVideo
import Foundation
import Testing
import UIKit
@testable import Echo

/// The camera in voice mode: with it open, a spoken question goes with a picture of what it
/// sees; shut, refused or blind, the question goes alone. A stand-in camera, since the
/// simulator has none; the making of a picture from a frame is tested on a frame made here.
@MainActor
struct VoiceLookTests {
    /// A camera that sees a different picture each time it is asked, and counts.
    final class FakeEye: VoiceLooking {
        var isAvailable = true
        var allowed = true
        var sees = true
        private(set) var opens = 0
        private(set) var closes = 0
        private(set) var stills = 0
        var viewfinder: AVCaptureSession? { nil }

        func open() async -> Bool { opens += 1; return allowed }
        func close() { closes += 1 }
        func still() -> Echo.Attachment? {
            guard sees else { return nil }
            stills += 1
            return Echo.Attachment(kind: .image, filename: "camera.jpg", mimeType: "image/jpeg", data: Data([0xFF, 0xD8, UInt8(stills)]))
        }
    }

    final class Notes { var taken: [String] = [] }

    struct Harness {
        let transport = CarBrevityTests.RecordingTransport()
        let conversation: Conversation
        let session: VoiceSession
        let recognizer = VoiceSessionTests.FakeRecognizer()
        let eye = FakeEye()
        let notes = Notes()

        init() {
            let settings = Settings(defaults: UserDefaults(suiteName: "look-\(UUID().uuidString)")!)
            settings.transport = .chatCompletions
            settings.fastLaneURL = "http://example.invalid:11500"
            settings.fastLaneModel = "test"
            let store = ConversationStore(directory: FileManager.default.temporaryDirectory.appending(path: "look-\(UUID().uuidString)"))
            conversation = Conversation(settings: settings, store: store, transportOverride: transport)
            session = VoiceSession(conversation: conversation, recognizer: recognizer, output: VoiceSessionTests.FakeSpeaker(),
                                   audio: VoiceSessionTests.FakeAudio(), eye: eye, requestPermissions: { true }, earcon: { _ in },
                                   keepAwake: { _ in }, talkOver: { .off }, interruption: { .speech }, shortInCar: { false },
                                   carConnected: { false }, takeNote: { [notes] in notes.taken.append($0) })
        }

        func until(_ what: @autoclosure () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(3)
            while !what(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        }

        /// Switches the camera on and waits for it to have answered.
        func look() async throws {
            let before = eye.opens
            session.setLooking(true)
            try await until(eye.opens > before)
            await Task.yield()
        }

        /// Asks by voice and gives back what the transport was sent.
        func ask(_ question: String = "What is this?") async throws -> TurnRequest {
            let before = transport.requests.count
            let starts = recognizer.starts
            session.beginListening()
            try await until(recognizer.starts > starts)
            recognizer.deliver(question)
            try await until(transport.requests.count > before)
            let request = try #require(transport.requests.last)
            session.cancel()
            return request
        }
    }

    // MARK: What goes with a question

    @Test func aQuestionAskedWithTheCameraOpenGoesWithWhatItSees() async throws {
        let h = Harness()
        try await h.look()
        #expect(h.session.isLooking)
        let request = try await h.ask()
        #expect(request.attachments.map(\.kind) == [.image])
        #expect(request.attachments.first?.filename == "camera.jpg")
        // And it stands in the conversation with the question, where the person can see what was sent.
        let asked = try #require(h.conversation.messages.first { $0.role == .user })
        #expect(asked.text == "What is this?")
        #expect(asked.attachments.count == 1)
    }

    @Test func withTheCameraShutAQuestionGoesAlone() async throws {
        let h = Harness()
        let request = try await h.ask()
        #expect(request.attachments.isEmpty)
        #expect(h.eye.opens == 0 && h.eye.stills == 0)
    }

    @Test func eachQuestionTakesItsOwnPicture() async throws {
        let h = Harness()
        try await h.look()
        let first = try await h.ask("What is this?")
        try await h.until(!h.conversation.isStreaming)
        let second = try await h.ask("And this?")
        #expect(h.eye.stills == 2)
        #expect(first.attachments.first?.data != second.attachments.first?.data)
        #expect(h.session.isLooking, "Stop leaves the camera open, for the next question about the same thing")
        #expect(h.eye.closes == 0)
    }

    @Test func aCameraThatSeesNothingSendsTheQuestionAlone() async throws {
        let h = Harness()
        try await h.look()
        h.eye.sees = false   // iOS took the camera away, or it is not up yet
        let request = try await h.ask()
        #expect(request.attachments.isEmpty)
        #expect(h.conversation.messages.contains { $0.role == .user && $0.text == "What is this?" }, "The question is still asked")
    }

    @Test func aNoteTakenWithTheCameraOpenTakesNoPicture() async throws {
        let h = Harness()
        try await h.look()
        h.session.beginListening(capturing: true)
        try await h.until(h.recognizer.starts == 1)
        h.recognizer.deliver("Milk and eggs")
        try await h.until(!h.notes.taken.isEmpty)
        #expect(h.notes.taken == ["Milk and eggs"])
        #expect(h.eye.stills == 0)
        #expect(h.transport.requests.isEmpty)
    }

    // MARK: The switch

    @Test func aCameraIOSRefusesIsSwitchedOffAgainAndSaysWhy() async throws {
        let h = Harness()
        h.eye.allowed = false
        try await h.look()
        try await h.until(!h.session.isLooking)
        #expect(!h.session.isLooking)
        #expect(h.session.lookProblem?.contains("Settings") == true)
        let request = try await h.ask()
        #expect(request.attachments.isEmpty)
        // Trying again clears what was said.
        h.eye.allowed = true
        try await h.look()
        #expect(h.session.isLooking && h.session.lookProblem == nil)
    }

    @Test func switchingTheCameraOffClosesIt() async throws {
        let h = Harness()
        try await h.look()
        h.session.setLooking(false)
        #expect(!h.session.isLooking)
        #expect(h.eye.closes == 1)
        let request = try await h.ask()
        #expect(request.attachments.isEmpty)
    }

    @Test func aCameraSwitchedOffWhileItOpensIsClosed() async throws {
        let h = Harness()
        h.session.setLooking(true)
        h.session.setLooking(false)   // before iOS has answered
        try await h.until(h.eye.opens == 1)
        try await h.until(h.eye.closes == 2)
        #expect(!h.session.isLooking)
        #expect(h.eye.closes == 2, "Once at the switch, once more when the camera came up after all")
    }

    @Test func aDeviceWithNoCameraOffersNone() {
        let h = Harness()
        #expect(h.session.canLook)
        h.eye.isAvailable = false
        #expect(!h.session.canLook)
    }

    // MARK: A picture from a frame

    static func frame(width: Int, height: Int) throws -> CVPixelBuffer {
        var made: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &made)
        return try #require(made)
    }

    @Test func aFrameLyingOnItsSideIsStoodUpright() throws {
        // A phone held upright gives frames wider than tall, and iOS says to turn them 90°.
        let frame = try Self.frame(width: 640, height: 360)
        let upright = try #require(CameraStill.attachment(from: frame, angle: 90))
        #expect(upright.kind == .image && upright.mimeType == "image/jpeg")
        let picture = try #require(UIImage(data: upright.data))
        #expect(picture.size == CGSize(width: 360, height: 640))
        // Held on its side, the frame is already the right way up.
        let level = try #require(CameraStill.attachment(from: frame, angle: 0))
        #expect(UIImage(data: level.data)?.size == CGSize(width: 640, height: 360))
    }

    @Test func theTurnIOSAsksForIsTheOrientationThePictureGets() {
        #expect(CameraStill.orientation(angle: 0) == .up)
        #expect(CameraStill.orientation(angle: 90) == .right)
        #expect(CameraStill.orientation(angle: 180) == .down)
        #expect(CameraStill.orientation(angle: 270) == .left)
        #expect(CameraStill.orientation(angle: 360) == .up)
        #expect(CameraStill.orientation(angle: -90) == .left)
    }

    @Test func aFrameFromBeforeTheCameraWasTakenAwayIsNotWhatItSeesNow() throws {
        let feed = CameraFeed()
        #expect(feed.newest(within: 1) == nil, "Nothing seen yet")
        let frame = try Self.frame(width: 64, height: 36)
        feed.keep(frame, at: .now.addingTimeInterval(-5))
        #expect(feed.newest(within: 1) == nil)
        feed.keep(frame)
        let (_, angle) = try #require(feed.newest(within: 1))
        #expect(angle == 90, "Upright, until a camera says otherwise")
    }
}
