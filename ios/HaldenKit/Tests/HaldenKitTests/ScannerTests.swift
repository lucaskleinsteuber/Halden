import Foundation
import HaldenKit
import Testing

@Suite("Viewfinder Scanner & QR Parsing")
struct ScannerTests {
    @Test("Parses HTTPS/HTTP/mailto/tel URLs and rejects unsafe schemes as plain text")
    func urlParsingAndSafety() {
        let https = QRPayloadParser.parse("https://example.com/photos?id=42")
        #expect(https?.pillTitle == "example.com")
        if case .url(let url) = https?.kind {
            #expect(url.absoluteString == "https://example.com/photos?id=42")
        } else {
            Issue.record("expected .url")
        }

        // Dangerous schemes never become clickable URLs.
        let js = QRPayloadParser.parse("javascript:alert(1)")
        if case .text(let t) = js?.kind {
            #expect(t == "javascript:alert(1)")
        } else {
            Issue.record("javascript: must be treated as plain text")
        }

        let file = QRPayloadParser.parse("file:///etc/passwd")
        if case .text = file?.kind {
        } else {
            Issue.record("file: must be treated as plain text")
        }

        #expect(QRPayloadParser.parse("   ") == nil)
    }

    @Test("Parses Wi-Fi QR codes including escaped semicolons and colons")
    func wifiParsing() {
        let qr = QRPayloadParser.parse(#"WIFI:T:WPA;S:Home\;5G;P:sec\:ret\;123;H:true;;"#)
        #expect(qr?.pillTitle == #"Join "Home;5G""#)
        if case .wifi(let ssid, let pass, let sec, let hidden) = qr?.kind {
            #expect(ssid == "Home;5G")
            #expect(pass == "sec:ret;123")
            #expect(sec == "WPA")
            #expect(hidden == true)
        } else {
            Issue.record("expected .wifi")
        }

        // Open network without password.
        let open = QRPayloadParser.parse("WIFI:T:nopass;S:CafeGuest;;")
        if case .wifi(let ssid, let pass, _, let hidden) = open?.kind {
            #expect(ssid == "CafeGuest")
            #expect(pass == nil)
            #expect(hidden == false)
        } else {
            Issue.record("expected open .wifi")
        }
    }

    @Test("Parses vCard, MECARD, and Halden pairing QR codes")
    func contactAndPairingParsing() {
        let vcard = """
            BEGIN:VCARD
            VERSION:3.0
            FN:Ada Lovelace
            TEL:+49123456789
            EMAIL:ada@example.org
            END:VCARD
            """
        let parsed = QRPayloadParser.parse(vcard)
        #expect(parsed?.pillTitle == "Ada Lovelace")
        if case .contact(let name, let phone, let email, _) = parsed?.kind {
            #expect(name == "Ada Lovelace")
            #expect(phone == "+49123456789")
            #expect(email == "ada@example.org")
        } else {
            Issue.record("expected .contact")
        }

        let mecard = QRPayloadParser.parse("MECARD:N:Turing,Alan;TEL:12345;EMAIL:alan@bletchley.uk;;")
        if case .contact(let name, let phone, let email, _) = mecard?.kind {
            #expect(name == "Alan Turing")
            #expect(phone == "12345")
            #expect(email == "alan@bletchley.uk")
        } else {
            Issue.record("expected MECARD .contact")
        }

        let pair = QRPayloadParser.parse("halden://pair?code=ABC12-DEF34")
        if case .haldenPairing(let link) = pair?.kind {
            #expect(link == "halden://pair?code=ABC12-DEF34")
        } else {
            Issue.record("expected .haldenPairing")
        }
    }

    @Test("Hold state keeps detected QR visible briefly and clears after timeout")
    func holdStateDebounce() {
        var state = ScannerHoldState(holdSeconds: 1.5)
        #expect(state.update(raw: nil, now: 10.0) == nil)
        let detected = state.update(raw: "https://halden.local", now: 10.5)
        #expect(detected?.pillTitle == "halden.local")
        // Still shown 1.0 s after disappearing.
        #expect(state.update(raw: nil, now: 11.5)?.pillTitle == "halden.local")
        // Cleared once 1.5 s have elapsed.
        #expect(state.update(raw: nil, now: 12.1) == nil)
    }
}
