import XCTest

@MainActor
final class SettingsViewModelTests: XCTestCase {
    private let validPin = Data(repeating: 1, count: 32).base64EncodedString()
    private let validToken = "wdn_" + String(repeating: "ab12cd34", count: 8)

    private struct Rig {
        let model: SettingsViewModel
        let settings: RecordingSettingsStore
        let secrets: any SecretStoring
        let manager: FakeExtensionManager
        let syncResumed: CallLatch
        let uploaderResumed: CallLatch
    }

    private func makeRig(secrets: any SecretStoring = InMemorySecretStore()) -> Rig {
        let settings = RecordingSettingsStore()
        let manager = FakeExtensionManager()
        let syncResumed = CallLatch()
        let uploaderResumed = CallLatch()
        let store = StoreHarness().makeStore()
        let model = SettingsViewModel(
            store: store, settings: settings, secrets: secrets, extensionManager: manager,
            resumeSync: { syncResumed.increment() }, resumeUploader: { uploaderResumed.increment() }
        )
        return Rig(
            model: model, settings: settings, secrets: secrets, manager: manager,
            syncResumed: syncResumed, uploaderResumed: uploaderResumed
        )
    }

    private func fillValid(_ model: SettingsViewModel) {
        model.serverURLText = "  https://warden.example.com \n"
        model.pinText = validPin
        model.tokenText = validToken
    }

    func testInvalidFieldsDisableSave() {
        let rig = makeRig()
        XCTAssertFalse(rig.model.canSave)
        fillValid(rig.model)
        XCTAssertTrue(rig.model.canSave)
        XCTAssertTrue(rig.model.issues.isEmpty)
        rig.model.serverURLText = "http://warden.example.com"
        XCTAssertFalse(rig.model.canSave)
        XCTAssertFalse(rig.model.issues.isEmpty)
    }

    func testSaveStoresTokenAndClearsField() async throws {
        let rig = makeRig()
        fillValid(rig.model)
        await rig.model.save()
        let stored = try await rig.secrets.token()
        XCTAssertEqual(stored, validToken)
        XCTAssertEqual(rig.model.tokenText, "")
    }

    func testSaveWritesSettingsAndResumesSyncAndUploader() async {
        let rig = makeRig()
        fillValid(rig.model)
        await rig.model.save()
        XCTAssertEqual(rig.settings.saveCalls.count, 1)
        XCTAssertEqual(rig.settings.load().serverURL?.absoluteString, "https://warden.example.com")
        XCTAssertEqual(rig.settings.load().spkiPin, validPin)
        XCTAssertEqual(rig.syncResumed.count, 1)
        XCTAssertEqual(rig.uploaderResumed.count, 1)
    }

    func testSaveDoesNothingWhenInvalid() async {
        let rig = makeRig()
        await rig.model.save()
        XCTAssertEqual(rig.settings.saveCalls.count, 0)
        XCTAssertEqual(rig.syncResumed.count, 0)
    }

    func testIssuesNeverContainToken() {
        let rig = makeRig()
        let secret = "wdn_DISTINCTIVE-SECRET-VALUE"
        rig.model.tokenText = secret
        XCTAssertFalse(rig.model.issues.isEmpty)
        XCTAssertFalse(rig.model.issues.joined(separator: " ").contains("DISTINCTIVE"))
    }

    func testTokenStoreFailureSurfacesSafeMessageAndKeepsState() async {
        let rig = makeRig(secrets: RejectingSecretStore())
        fillValid(rig.model)
        await rig.model.save()
        XCTAssertEqual(rig.model.tokenText, validToken)
        XCTAssertFalse(rig.model.issues.isEmpty)
        XCTAssertFalse(rig.model.issues.joined(separator: " ").contains(validToken))
        XCTAssertEqual(rig.syncResumed.count, 0)
        XCTAssertEqual(rig.uploaderResumed.count, 0)
        XCTAssertEqual(rig.settings.saveCalls.count, 0)
    }

    func testEditingClearsSaveFailure() async {
        let rig = makeRig(secrets: RejectingSecretStore())
        fillValid(rig.model)
        await rig.model.save()
        rig.model.tokenText = validToken
        XCTAssertTrue(rig.model.issues.isEmpty)
    }

    func testStoredTokenAllowsSavingWithoutRetyping() async {
        let rig = makeRig(secrets: RejectingSecretStore(storedToken: validToken))
        await rig.model.loadStoredToken()
        rig.model.serverURLText = "https://warden.example.com"
        rig.model.pinText = validPin
        XCTAssertTrue(rig.model.canSave)
        XCTAssertTrue(rig.model.issues.isEmpty)
        await rig.model.save()
        XCTAssertEqual(rig.settings.saveCalls.count, 1)
        XCTAssertEqual(rig.syncResumed.count, 1)
        XCTAssertEqual(rig.uploaderResumed.count, 1)
        XCTAssertTrue(rig.model.issues.isEmpty)
    }

    func testNoStoredTokenAndEmptyFieldBlocksSaveWithoutIssue() async {
        let rig = makeRig()
        await rig.model.loadStoredToken()
        rig.model.serverURLText = "https://warden.example.com"
        rig.model.pinText = validPin
        XCTAssertFalse(rig.model.canSave)
        XCTAssertTrue(rig.model.issues.isEmpty)
    }

    func testTypedInvalidTokenShowsIssueEvenWithStoredToken() async {
        let rig = makeRig(secrets: RejectingSecretStore(storedToken: validToken))
        await rig.model.loadStoredToken()
        rig.model.serverURLText = "https://warden.example.com"
        rig.model.pinText = validPin
        rig.model.tokenText = "wdn_bad"
        XCTAssertFalse(rig.model.canSave)
        XCTAssertFalse(rig.model.issues.isEmpty)
    }

    func testSaveMarksTokenAsStored() async {
        let rig = makeRig()
        fillValid(rig.model)
        await rig.model.save()
        XCTAssertTrue(rig.model.canSave)
    }

    func testSecondSaveWhileSavingIsIgnoredAndNewerTokenTextSurvives() async {
        let gated = GatedSecretStore()
        let rig = makeRig(secrets: gated)
        fillValid(rig.model)
        let model = rig.model
        let first = Task { await model.save() }
        await gated.entered.wait(for: 1)
        await model.save()
        XCTAssertEqual(gated.entered.count, 1)
        let newer = "wdn_" + String(repeating: "ef56ab78", count: 8)
        model.tokenText = newer
        gated.release()
        await first.value
        XCTAssertEqual(model.tokenText, newer)
        XCTAssertEqual(rig.settings.saveCalls.count, 1)
        XCTAssertEqual(rig.syncResumed.count, 1)
    }

    func testInstallAndUninstallDelegateToManager() async {
        let rig = makeRig()
        await rig.model.installTapped()
        await rig.model.uninstallTapped()
        XCTAssertEqual(rig.manager.installCalls.count, 1)
        XCTAssertEqual(rig.manager.uninstallCalls.count, 1)
    }

    func testExtensionStateText() async {
        let harness = StoreHarness()
        let store = harness.makeStore()
        harness.ext.continuation.yield(.failed("boom"))
        await harness.settle(store)
        let model = SettingsViewModel(
            store: store, settings: RecordingSettingsStore(), secrets: InMemorySecretStore(),
            extensionManager: FakeExtensionManager(), resumeSync: {}, resumeUploader: {}
        )
        XCTAssertEqual(model.extensionStateText, "boom")
    }

    private func makeModel(sync: SyncState, ext: ExtensionState) async -> SettingsViewModel {
        let harness = StoreHarness()
        let store = harness.makeStore()
        harness.sync.continuation.yield(sync)
        harness.ext.continuation.yield(ext)
        await harness.settle(store)
        return SettingsViewModel(
            store: store, settings: RecordingSettingsStore(), secrets: InMemorySecretStore(),
            extensionManager: FakeExtensionManager(), resumeSync: {}, resumeUploader: {}
        )
    }

    func testFullDiskAccessHintWhenActiveExtensionIsUnreachable() async {
        let model = await makeModel(sync: .extensionUnavailable(version: 3), ext: .active)
        XCTAssertEqual(model.fullDiskAccessHint, "Open System Settings → Privacy & Security → Full Disk Access")
    }

    func testNoFullDiskAccessHintOtherwise() async {
        let synced = await makeModel(sync: .synced(version: 3, at: EventFixture.now), ext: .active)
        XCTAssertNil(synced.fullDiskAccessHint)
        let notInstalled = await makeModel(sync: .extensionUnavailable(version: 3), ext: .notInstalled)
        XCTAssertNil(notInstalled.fullDiskAccessHint)
        let awaiting = await makeModel(sync: .extensionUnavailable(version: 3), ext: .awaitingApproval)
        XCTAssertNil(awaiting.fullDiskAccessHint)
    }

    func testFreshFormShowsNoIssuesButCannotSave() {
        let rig = makeRig()
        XCTAssertTrue(rig.model.issues.isEmpty)
        XCTAssertFalse(rig.model.canSave)
    }

    func testIssuesAppearAfterEditing() {
        let rig = makeRig()
        rig.model.pinText = "x"
        XCTAssertFalse(rig.model.issues.isEmpty)
    }

    func testIssuesAppearAfterSaveAttempt() async {
        let rig = makeRig()
        await rig.model.save()
        XCTAssertFalse(rig.model.issues.isEmpty)
    }
}
