import Foundation
import Testing

@testable import Heeler

/// Agent detail's Host telemetry label (#236): what it shows, what it
/// refuses to show, and that it can never disagree with the Hosts sheet.
@Suite("Host telemetry presentation")
struct HostTelemetryPresentationTests {
    @Test func connectedHostShowsTheRoundedRoundTrip() throws {
        let presentation = try #require(
            HostTelemetryPresentation(
                status: .connected,
                latency: .milliseconds(25) + .microseconds(600)))

        #expect(presentation.title == "26 ms")
        #expect(presentation.accessibilityLabel == "Host API connection latency")
        #expect(presentation.accessibilityValue == "26 milliseconds over SSH")
    }

    @Test func subMillisecondLatencyNeverRoundsToZero() throws {
        let presentation = try #require(
            HostTelemetryPresentation(status: .connected, latency: .microseconds(400)))

        #expect(presentation.title == "<1 ms")
        #expect(presentation.accessibilityValue == "Less than 1 millisecond over SSH")
    }

    @Test func oneMillisecondIsTheFirstSpokenSingular() throws {
        let presentation = try #require(
            HostTelemetryPresentation(status: .connected, latency: .milliseconds(1)))

        #expect(presentation.title == "1 ms")
        #expect(presentation.accessibilityValue == "1 millisecond over SSH")
    }

    /// The floor is the value, not the rounding: 1.4 ms is a measured
    /// millisecond and reads as one, while 0.999 ms stays below the floor.
    @Test func roundingCrossesTheFloorOnValueNotOnDisplay() throws {
        #expect(
            HostTelemetryPresentation(
                status: .connected, latency: .microseconds(1_400)
            )?.title == "1 ms")
        #expect(
            HostTelemetryPresentation(
                status: .connected, latency: .microseconds(999)
            )?.title == "<1 ms")
        #expect(
            HostTelemetryPresentation(
                status: .connected, latency: .microseconds(1_500)
            )?.title == "2 ms")
    }

    @Test func connectedWithoutAMeasurementRendersNothing() {
        #expect(HostTelemetryPresentation(status: .connected, latency: nil) == nil)
    }

    @Test func everyUnprovenStatusRendersNothingEvenWithALatency() {
        let latency = Duration.milliseconds(42)
        let unproven: [EventsSessionStatus?] = [
            .connecting,
            .reconnecting(attempt: 1, delay: .seconds(1), failure: .timedOut),
            .failed(.authenticationFailed),
            .suspended,
            .ended,
            nil,
        ]

        for status in unproven {
            #expect(
                HostTelemetryPresentation(status: status, latency: latency) == nil,
                "\(String(describing: status)) must not show a latency")
        }
    }

    /// The Hosts sheet chip and this label read the same measurement, so a
    /// user comparing the two surfaces must never see two numbers.
    @Test func theNumberMatchesTheHostsSheetChip() throws {
        let latencies: [Duration] = [
            .microseconds(1),
            .microseconds(400),
            .microseconds(999),
            .milliseconds(1),
            .microseconds(1_500),
            .milliseconds(34),
            .milliseconds(25) + .microseconds(600),
            .seconds(1) + .milliseconds(250),
        ]

        for latency in latencies {
            let chip = HostConnectionPresentation(status: .connected, latency: latency)
            let label = try #require(
                HostTelemetryPresentation(status: .connected, latency: latency))
            #expect(label.title == chip.title)
        }
    }

    /// A clock that moved under the sample must not render backwards.
    @Test func negativeMeasurementsClampRatherThanRenderBackwards() throws {
        let presentation = try #require(
            HostTelemetryPresentation(status: .connected, latency: .milliseconds(-5)))

        #expect(presentation.title == "<1 ms")
        #expect(
            HostConnectionPresentation(
                status: .connected, latency: .milliseconds(-5)
            ).title == "<1 ms")
    }
}
