import XCTest
@testable import AppLocalVoice

@MainActor
final class SpeechConfigurationTests: XCTestCase {
    func testDefaultLocaleIsCapturedInConfigurationForSourceCompatibility() {
        let configuration = SpeechConfiguration()
        XCTAssertEqual(configuration.locale, .current)
        XCTAssertEqual(configuration.preferredQuality, .premium)

        let explicit = SpeechConfiguration(locale: Locale(identifier: "vi-VN"))
        XCTAssertEqual(explicit.locale.identifier, "vi-VN")
    }

    func testExactLocaleWinsBeforeSameLanguageFallback() throws {
        let voices = [
            SpeechVoice(id: "en-au-enhanced", name: "Australian", languageIdentifier: "en-AU", quality: .enhanced),
            SpeechVoice(id: "en-us-compact", name: "American", languageIdentifier: "en-US", quality: .compact),
            SpeechVoice(id: "en-gb-enhanced", name: "British", languageIdentifier: "en-GB", quality: .enhanced)
        ]

        let selected = try AppleSpeechOutput.selectVoiceID(
            from: voices,
            locale: Locale(identifier: "en-US"),
            preferredQuality: .enhanced,
            voiceIdentifier: nil
        )

        XCTAssertEqual(selected, "en-us-compact")
    }

    func testSameLanguageFallsBackDeterministicallyWhenRegionIsUnavailable() throws {
        let voices = [
            SpeechVoice(id: "en-us", name: "US", languageIdentifier: "en-US", quality: .compact),
            SpeechVoice(id: "en-gb", name: "UK", languageIdentifier: "en-GB", quality: .compact)
        ]

        let first = try AppleSpeechOutput.selectVoiceID(
            from: voices,
            locale: Locale(identifier: "en-CA"),
            preferredQuality: .compact,
            voiceIdentifier: nil
        )
        let second = try AppleSpeechOutput.selectVoiceID(
            from: voices,
            locale: Locale(identifier: "en-CA"),
            preferredQuality: .compact,
            voiceIdentifier: nil
        )

        XCTAssertEqual(first, "en-gb")
        XCTAssertEqual(first, second)
    }

    func testQualityFallbackPrefersHigherAvailableQualityAfterRequestedQuality() throws {
        let voices = [
            SpeechVoice(id: "en-compact", name: "Compact", languageIdentifier: "en-US", quality: .compact),
            SpeechVoice(id: "en-premium", name: "Premium", languageIdentifier: "en-US", quality: .premium)
        ]

        XCTAssertEqual(
            try AppleSpeechOutput.selectVoiceID(
                from: voices,
                locale: Locale(identifier: "en-US"),
                preferredQuality: .enhanced,
                voiceIdentifier: nil
            ),
            "en-premium"
        )

        let withEnhanced = voices + [
            SpeechVoice(id: "en-enhanced", name: "Enhanced", languageIdentifier: "en-US", quality: .enhanced)
        ]
        XCTAssertEqual(
            try AppleSpeechOutput.selectVoiceID(
                from: withEnhanced,
                locale: Locale(identifier: "en-US"),
                preferredQuality: SpeechConfiguration().preferredQuality,
                voiceIdentifier: nil
            ),
            "en-premium"
        )
    }

    func testDifferentLanguageDoesNotSilentlyFallBackToCurrentOrEnglish() {
        let voices = [SpeechVoice(id: "en-us", name: "US", languageIdentifier: "en-US", quality: .enhanced)]

        XCTAssertThrowsError(try AppleSpeechOutput.selectVoiceID(
            from: voices,
            locale: Locale(identifier: "vi-VN"),
            preferredQuality: .enhanced,
            voiceIdentifier: nil
        )) { error in
            XCTAssertEqual(error as? VoiceError, .speechVoiceUnavailable("vi-VN"))
        }
    }

    func testExplicitVoiceMustMatchRequestedLanguage() {
        let voices = [
            SpeechVoice(id: "en-us", name: "US", languageIdentifier: "en-US", quality: .enhanced),
            SpeechVoice(id: "vi-vn", name: "Vietnamese", languageIdentifier: "vi-VN", quality: .enhanced)
        ]

        XCTAssertThrowsError(try AppleSpeechOutput.selectVoiceID(
            from: voices,
            locale: Locale(identifier: "en-US"),
            preferredQuality: .enhanced,
            voiceIdentifier: "vi-vn"
        )) { error in
            guard case .invalidSpeechConfiguration = error as? VoiceError else {
                return XCTFail("Expected a locale mismatch configuration error")
            }
        }
    }

    func testInvalidSpeechConfigurationsAreRejectedBeforeSynthesis() {
        let invalidConfigurations = [
            SpeechConfiguration(locale: Locale(identifier: "")),
            SpeechConfiguration(rate: -0.01),
            SpeechConfiguration(volume: 1.01),
            SpeechConfiguration(maximumCharactersPerUtterance: 127),
            SpeechConfiguration(maximumCharactersPerUtterance: 32_001)
        ]

        for configuration in invalidConfigurations {
            XCTAssertThrowsError(try AppleSpeechOutput.validate(configuration)) { error in
                guard case .invalidSpeechConfiguration = error as? VoiceError else {
                    return XCTFail("Expected invalid speech configuration, got \(error)")
                }
            }
        }
    }

    func testSpeechTextLimitFailsBeforeChunking() {
        let oversized = String(repeating: "x", count: VoiceTextLimits.maximumUTF16Length + 1)

        XCTAssertThrowsError(try AppleSpeechOutput.validateText(oversized)) { error in
            XCTAssertEqual(
                error as? VoiceError,
                .textTooLong(maximumUTF16Length: VoiceTextLimits.maximumUTF16Length)
            )
        }
        XCTAssertNoThrow(try AppleSpeechOutput.validateText("x"))
    }
}
