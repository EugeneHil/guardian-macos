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
}
