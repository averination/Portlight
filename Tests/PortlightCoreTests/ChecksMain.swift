import Foundation

// A dependency-free runner: Command Line Tools ship Swift but may not ship XCTest.
private enum Checks {
    static var assertions = 0
    static var failures = 0
    static func verify(_ pass: Bool, _ message: String, file: StaticString, line: UInt) {
        assertions += 1
        if !pass { failures += 1; print("FAIL \(file):\(line) \(message)") }
    }
}
func expectTrue(_ value: Bool, _ message: String = "expected true", file: StaticString = #file, line: UInt = #line) {
    Checks.verify(value, message, file: file, line: line)
}
func expectFalse(_ value: Bool, _ message: String = "expected false", file: StaticString = #file, line: UInt = #line) {
    Checks.verify(!value, message, file: file, line: line)
}
func expectEqual<T: Equatable>(_ a: T, _ b: T, file: StaticString = #file, line: UInt = #line) {
    Checks.verify(a == b, "\(a) != \(b)", file: file, line: line)
}
func expectNotEqual<T: Equatable>(_ a: T, _ b: T, file: StaticString = #file, line: UInt = #line) {
    Checks.verify(a != b, "unexpected equality", file: file, line: line)
}
func expectNil<T>(_ value: T?, _ message: String = "expected nil", file: StaticString = #file, line: UInt = #line) {
    Checks.verify(value == nil, message, file: file, line: line)
}
func expectNotNil<T>(_ value: T?, file: StaticString = #file, line: UInt = #line) {
    Checks.verify(value != nil, "unexpected nil", file: file, line: line)
}
struct CheckError: Error { let message: String }
struct SkipCheck: Error { let reason: String; init(_ reason: String) { self.reason = reason } }
func requireValue<T>(_ value: T?) throws -> T {
    guard let value else { throw CheckError(message: "Required value was nil") }; return value
}

@main
struct ChecksMain {
    static func main() async {
        let unit = DiscoveryTests(), live = LiveTests(), notch = NotchTests(), archive = ArchiveTests()
        let publication = PublicationTests(), grouping = GroupingTests()
        let tests: [(String, () async throws -> Void)] = [
            ("project groups / persistence / overrides / legacy archive / source isolation", grouping.testPersistentGroupingDoesNotVerifyProcessSource),
            ("LIVE project groups / changed scope rejected / manual Codex SIGTERM", grouping.testLiveManualGroupRevalidatedBeforeStop),
            ("publication selected files / literal paths / preserve staging / no implicit push", publication.testSelectedWholeFilesPreserveOtherStaging),
            ("publication stale review / conflicts / nested root / credentials", publication.testReviewRejectsStaleFilesConflictsAndNestedRoots),
            ("publication local bare push / all pending commits / no remote overwrite", publication.testPushUsesReviewedCommitAndRefusesRemoteDivergence),
            ("publication rename / delete / explicit branch only / no tags or mirror", publication.testRenamesDeletionsAndPushScope),
            ("publication config persistence / exact production deployment", publication.testConfigurationAndProductionStatusAreSpecific),
            ("launch outcome / SIGTERM vs wrapper exit / real failures", archive.testLaunchOutcomeDistinguishesStopsFromFailures),
            ("archive recipes / package manager / dev tasks only", archive.testRecipesChooseManagerAndOnlyServerTasks),
            ("archive persistence / symlink dedup / selection / private file", archive.testArchiveSurvivesRestartDeduplicatesAndPreservesSelection),
            ("archive corruption / missing folder / removed task", archive.testCorruptArchiveAndMissingProjectFailWithoutOverwriting),
            ("LIVE archive launch / port / duplicate / forget / SIGTERM", archive.testLiveLaunchDiscoversPortAndRejectsDuplicate),
            ("LIVE failed launch / exit code / private log", archive.testFailedLaunchReportsExitAndLog),
            ("LIVE wrapped SIGTERM 143 / restart / genuine runtime failure", archive.testLiveWrappedSIGTERMAndRestartFailure),
            ("notch geometry / negative display origins / hit area", notch.testGeometryKeepsEveryStateBelowCutout),
            ("notch outline / concave shoulders / anchored morph", notch.testOutlineHasConcaveShouldersAndKeepsMorphAnchored),
            ("origin attribution / no name guessing / stale chain", notch.testOriginDoesNotUseProjectOrRuntimeNames),
            ("LIVE signed Codex origin / tab scope / partial result", live.testAttributionAndCategoryScope),
            ("lsof parser / duplicate FDs / owner isolation", unit.testParsesActualLsofFieldFormatAndDeduplicatesDescriptors),
            ("IPv6 and wildcard URL", unit.testIPv6AndWildcardURLs),
            ("exact runtime whitelist", unit.testExecutableWhitelistIsExactAndSupportsVersionedPython),
            ("requires eligible TCP listener", unit.testOrdinaryRuntimeProcessNeedsAnEligibleListener),
            ("multiple ports share a row", unit.testMultiplePortsAndAddressFamiliesStayInOneProcessRow),
            ("Next worker and parent separation", unit.testRenamedNextWorkerUsesRealExecutableAndKeepsParentSeparate),
            ("owner / root / privilege / ancestor protection", unit.testForeignRootPrivilegedAndAncestorProcessesAreExcluded),
            ("missing metadata fails closed", unit.testMissingMetadataFailsClosed),
            ("background helper exclusion", unit.testBackgroundInfrastructureExcludedEvenInsideProject),
            ("framework Python exception", unit.testFrameworkPythonIsAllowedButAppEmbeddedPythonIsNot),
            ("custom server requires project evidence", unit.testCustomServerRequiresProjectButPythonHTTPWorksWithoutMarker),
            ("debugger port exclusion", unit.testInspectorsAreNotShownAsServers),
            ("stale identity and changed scope protection", unit.testStopRequiresSameIdentityExecutableDirectoryAndEndpoints),
            ("LIVE Python discovery / selective SIGTERM", live.testLiveDiscoveryAndSIGTERMOnlyTouchesChosenListener),
            ("LIVE exact batch of two / survivor", live.testBatchStopsExactlyTwoSelectedServers),
            ("LIVE Node child / IPv4+IPv6 / frozen batch", live.testNodeChildMultiPortAndBatchSnapshot),
            ("LIVE ignored SIGTERM remains visible", live.testIgnoringSIGTERMRemainsVisibleWithoutEscalation)
        ]
        var passed = 0, skipped = 0
        for (name, body) in tests {
            let before = Checks.failures
            do {
                try await body()
                if before == Checks.failures { passed += 1; print("PASS \(name)") }
            } catch let skip as SkipCheck { skipped += 1; print("SKIP \(name): \(skip.reason)") }
            catch { Checks.failures += 1; print("FAIL \(name): \(error)") }
        }
        print("\(passed) passed, \(skipped) skipped, \(Checks.failures) failures; \(Checks.assertions) assertions")
        exit(Checks.failures == 0 ? 0 : 1)
    }
}
