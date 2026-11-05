import Foundation

enum ModelRPCChecks {
    static func run() throws {
        let fixture = URL(fileURLWithPath: ".build/model-probe-server.py")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let handshake = """
        import json,time
        r=json.loads(input()); assert r['method']=='initialize'
        print(json.dumps({'id':r['id'],'result':{}}),flush=True)
        assert json.loads(input())['method']=='initialized'
        r=json.loads(input()); assert r['method']=='turn/start'
        assert r['params']['approvalPolicy']=='never'
        assert r['params']['sandboxPolicy']['type']=='readOnly'
        """
        func write(_ body: String) throws {
            try ("#!/usr/bin/env python3\n" + handshake + "\n" + body).write(to: fixture, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.path)
        }
        try write("""
        print(json.dumps({'method':'item/completed','params':{'threadId':'probe','item':{'type':'agentMessage','phase':'final_answer','text':'[11,27,18]'}}}),flush=True)
        print(json.dumps({'id':r['id'],'result':{'turn':{'id':'turn'}}}),flush=True)
        print(json.dumps({'method':'turn/completed','params':{'threadId':'probe','turn':{'id':'turn','status':'completed'}}}),flush=True)
        time.sleep(30)
        """)
        let successful = CodexAppServer()
        try successful.connect(executable: fixture)
        let answer = try successful.answer(threadID: "probe", prompt: "numbers", effort: "low", timeout: 1)
        assert(answer == "[11,27,18]")
        successful.close()

        try write("""
        print(json.dumps({'id':77,'method':'item/commandExecution/requestApproval','params':{'threadId':'probe'}}),flush=True)
        rejection=json.loads(input()); assert rejection['id']==77 and 'error' in rejection
        time.sleep(30)
        """)
        let denied = CodexAppServer()
        try denied.connect(executable: fixture)
        do {
            _ = try denied.answer(threadID: "probe", prompt: "numbers", effort: "low", timeout: 1)
            assertionFailure("Probe approvals must be declined, never treated as completed answers")
        } catch { assert(error.localizedDescription.contains("工具或授权")) }
        denied.close()

        try write("""
        print(json.dumps({'id':r['id'],'result':{'turn':{'id':'turn'}}}),flush=True)
        print(json.dumps({'method':'error','params':{'error':{'message':'服务暂不可用'},'willRetry':False}}),flush=True)
        time.sleep(30)
        """)
        let failed = CodexAppServer()
        try failed.connect(executable: fixture)
        do {
            _ = try failed.answer(threadID: "probe", prompt: "numbers", effort: "low", timeout: 1)
            assertionFailure("Connection-level inference failures must surface immediately")
        } catch { assert(error.localizedDescription == "服务暂不可用") }
        failed.close()

        try write("""
        print(json.dumps({'id':r['id'],'result':{'turn':{'id':'turn'}}}),flush=True)
        interrupted=json.loads(input()); assert interrupted['method']=='turn/interrupt'
        time.sleep(30)
        """)
        let timed = CodexAppServer()
        try timed.connect(executable: fixture)
        let began = Date()
        do {
            _ = try timed.answer(threadID: "probe", prompt: "numbers", effort: "low", timeout: 0.1)
            assertionFailure("A probe that never completes must time out")
        } catch { assert(error.localizedDescription.contains("超时")) }
        timed.close()
        assert(Date().timeIntervalSince(began) < 3)
        print("Probe streaming, approval refusal, timeout and cleanup checks passed")
    }
}
