import Foundation
import OttoModels
import Testing

@testable import OttoRuntime

@Suite("Live profile model catalogs")
struct LiveModelCatalogTests {
  private func stub(_ body: String, signedIn: Bool = true) throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appending(path: "model-probe-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appending(path: "provider")
    try
      ("#!/usr/bin/python3\nimport json,sys,os,time,signal\nif '--version' in sys.argv: print('1.0'); sys.exit(0)\n"
      + "if sys.argv[1:3] == ['auth','status']: print(json.dumps({'loggedIn': \(signedIn ? "True" : "False")})); sys.exit(0)\n"
      + body)
      .write(to: file, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
    return file
  }

  @Test func codexHandshakePaginationAndAccount() async throws {
    let file = try stub(
      #"""
      def reply(value): print(json.dumps(value),flush=True)
      request=json.loads(input())
      assert request['method']=='initialize'
      reply({'method':'notice'})
      reply({'id':request['id'],'result':{}})
      assert json.loads(input())['method']=='initialized'
      request=json.loads(input())
      assert request['method']=='account/read'
      reply({'id':request['id'],'result':{'account':{'type':'chatgpt'}}})
      request=json.loads(input())
      assert request['method']=='model/list'
      reply({'id':request['id'],'result':{'data':[
        {'model':os.environ['CODEX_HOME'],'displayName':'Account model'},
        {'model':'hidden-model','hidden':True}], 'nextCursor':'page2'}})
      request=json.loads(input())
      assert request['params']['cursor']=='page2'
      reply({'id':request['id'],'result':{'data':[
        {'model':os.environ['CODEX_HOME']},
        {'model':'new-model','displayName':'Newest'}], 'nextCursor':None}})
      time.sleep(30)
      """#)
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    for account in ["personal", "work"] {
      let models = await LiveModelCatalog.discover(
        provider: .codex, executable: file.path, environment: ["CODEX_HOME": account])
      #expect(models?.map(\.id) == [account, "new-model"])
      #expect(models?.last?.displayName == "Newest")
    }
  }

  @Test func claudeInitializationReportsAliasesAndNames() async throws {
    let file = try stub(
      #"""
      assert '--no-session-persistence' in sys.argv
      assert '--strict-mcp-config' in sys.argv
      request=json.loads(input())
      assert request['request']=={'subtype':'initialize'}
      print(json.dumps({'type':'control_response','response':{
        'subtype':'success','request_id':request['request_id'],'response':{'models':[
          {'value':'opus','displayName':'Opus newest','resolvedModel':'claude-opus-new'},
          {'value':os.environ['CLAUDE_CONFIG_DIR'],'displayName':'Profile model'}]}}}),flush=True)
      time.sleep(30)
      """#)
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    for account in ["personal", "work"] {
      let models = await ClaudeCodeAdapter(executablePath: file.path).availableModels(
        environment: ["CLAUDE_CONFIG_DIR": account])
      #expect(models.map(\.id) == ["opus", account])
      #expect(models.first?.displayName == "Opus newest")
    }
  }

  @Test func errorsDoNotBecomeAnInventedCatalog() async throws {
    let file = try stub(
      #"""
      request=json.loads(input())
      print(json.dumps({'type':'control_response','response':{
        'subtype':'error','request_id':request['request_id'],'error':'not authenticated'}}),flush=True)
      """#)
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let result = await LiveModelCatalog.discover(
      provider: .claudeCode, executable: file.path, environment: [:])
    #expect(result == nil)
  }

  @Test func repeatedPaginationCursorFails() async throws {
    let file = try stub(
      #"""
      request=json.loads(input())
      print(json.dumps({'id':request['id'],'result':{}}),flush=True)
      input()
      request=json.loads(input())
      print(json.dumps({'id':request['id'],'result':{'account':{'type':'chatgpt'}}}),flush=True)
      for i in range(2):
        request=json.loads(input())
        print(json.dumps({'id':request['id'],'result':{'data':[], 'nextCursor':'same'}}),flush=True)
      time.sleep(30)
      """#)
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    #expect(
      await LiveModelCatalog.discover(
        provider: .codex, executable: file.path, environment: [:]) == nil)
  }

  @Test func timeoutKillsUncooperativeProcess() async throws {
    let file = try stub(
      #"""
      signal.signal(signal.SIGTERM,signal.SIG_IGN)
      time.sleep(30)
      """#)
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let start = ContinuousClock.now
    #expect(
      await LiveModelCatalog.discover(
        provider: .codex, executable: file.path, environment: [:], timeout: 0.2) == nil)
    // Well under the stub's 30 s sleep; generous for a loaded CI runner.
    #expect(ContinuousClock.now - start < .seconds(5))
  }

  @Test func partialOutputAndEarlyExitDoNotHang() async throws {
    let file = try stub("print('{incomplete',end='',flush=True)\n")
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    #expect(
      await LiveModelCatalog.discover(
        provider: .claudeCode, executable: file.path, environment: [:], timeout: 1) == nil)
  }
  @Test(.enabled(if: ProcessInfo.processInfo.environment["OTTO_LIVE_MODEL_PROBE"] == "1"))
  func installedProviderCatalogs() async throws {
    let codex = try #require(await CodexAdapter().discoverLiveModels())
    let claude = try #require(await ClaudeCodeAdapter().discoverModels())
    #expect(!codex.isEmpty)
    #expect(!claude.isEmpty)
    if let expected = ProcessInfo.processInfo.environment["OTTO_EXPECT_CODEX_MODEL"] {
      #expect(codex.contains { $0.id == expected })
    }
    print("Codex installation: \(await CodexAdapter().detectInstallation())")
    print("Live Codex catalog: \(codex.map(\.id))")
    print("Live Claude catalog: \(claude.map(\.displayName))")
  }

  @Test func codexAPIKeyDoesNotBorrowLogin() async {
    #expect(await CodexAdapter().discoverLiveModels(environment: ["CODEX_API_KEY": "test"]) == nil)
  }

  @Test func unauthenticatedCodexDoesNotShowBuiltInModels() async throws {
    let file = try stub(
      #"""
      request=json.loads(input())
      print(json.dumps({'id':request['id'],'result':{}}),flush=True)
      input()
      request=json.loads(input())
      assert request['method']=='account/read'
      print(json.dumps({'id':request['id'],'result':{'account':None}}),flush=True)
      time.sleep(30)
      """#)
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    #expect(
      await LiveModelCatalog.discover(
        provider: .codex, executable: file.path, environment: [:]) == nil)
  }

  @Test func defaultClaudeKeepsItsDefaultKeychainNamespace() async throws {
    let file = try stub(
      #"""
      request=json.loads(input())
      print(json.dumps({'type':'control_response','response':{
        'subtype':'success','request_id':request['request_id'],'response':{'models':[
          {'value':os.environ.get('CLAUDE_CONFIG_DIR','machine-login')}]}}}),flush=True)
      """#)
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let models = await ClaudeCodeAdapter(executablePath: file.path).availableModels()
    #expect(models.map(\.id) == ["machine-login"])
  }

  @Test func unauthenticatedClaudeDoesNotShowGenericAliases() async throws {
    let file = try stub(
      "raise RuntimeError('Must not initialize an unsigned-in profile')\n", signedIn: false)
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    #expect(
      await ClaudeCodeAdapter(executablePath: file.path).discoverModels(
        environment: ["CLAUDE_CONFIG_DIR": file.deletingLastPathComponent().path]) == nil)
  }

  @Test func desktopCodexLauncherPrecedesLegacyAndPATH() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "codex-layout-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let apps = root.appending(path: "Applications")
    let modern = apps.appending(path: "ChatGPT.app/Contents/Resources/codex-cli/bin/codex")
    let legacy = apps.appending(path: "ChatGPT.app/Contents/Resources/codex")
    let standalone = root.appending(path: "bin/codex")
    for file in [modern, legacy, standalone] {
      try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try "#!/bin/sh\nprintf 'codex-cli test\\n'\n".write(
        to: file, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
    }
    for expected in [modern, legacy, standalone] {
      let candidates = CodexAdapter.executableCandidates(
        applicationDirectories: [apps.path],
        environment: ["PATH": standalone.deletingLastPathComponent().path], homeDirectory: root.path
      )
      let installation = await ExecutableLocator.firstWorking(candidates: candidates)
      #expect(installation?.path == expected.path)
      try FileManager.default.removeItem(at: expected)
    }
  }

}
