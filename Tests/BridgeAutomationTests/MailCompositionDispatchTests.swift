import XCTest
import BridgeCore
@testable import BridgeAutomation

final class MailCompositionDispatchTests:XCTestCase {
    private func fixture() throws -> (NativeCompositionPlan,MailDraft) {
        let proposal=MailWorkflowComposition(accountID:"mail:owner",sender:"owner@example.com",to:["recipient@example.com"],cc:[],bcc:[],subject:"Synthetic",body:"Not sent.",delivery:.save)
        var request=try MailWorkflowRequest(action:.compose,accountIDs:[proposal.accountID])
        var report=MailWorkflowReport(requestID:request.id,expectedRevision:0,stage:.ready,summary:"Proposal",items:[])
        report.composition=proposal; try request.accept(report)
        var settings=MailSettings()
        let native=NativeMailAccount(id:"owner",name:"Owner",addresses:[proposal.sender],server:"imap.example.com")
        settings.nativeAccounts=[native]
        // Use a verified Gmail inventory to construct an externally public account value.
        var connection=MailConnection(id:"profile",email:proposal.sender,connectionID:"connection")
        connection.observedAt=Date(); settings.connections=[connection]
        let accounts=try MailWorkflowAccount.available(settings:settings,native:NativeMailState())
        var gmail=proposal; gmail.accountID="gmail:profile"
        request=try MailWorkflowRequest(action:.compose,accountIDs:[gmail.accountID])
        report=MailWorkflowReport(requestID:request.id,expectedRevision:0,stage:.ready,summary:"Proposal",items:[])
        report.composition=gmail; try request.accept(report)
        let plan=try NativeCompositionPlan(request:request,displayedRevision:1,displayed:gmail,accounts:accounts,nativeAccounts:[native])
        return (plan,MailDraft(id:42,subject:gmail.subject,sender:gmail.sender,to:gmail.to,cc:[],bcc:[],body:gmail.body,attachmentCount:0))
    }
    func testConsumePrecedesExactlyOneCreation() async throws {
        let (plan,draft)=try fixture()
        var calls:[String]=[]
        let result=try await MailCompositionDispatch.perform(plan:plan,check:{calls.append("check")},consume:{calls.append("consume")},create:{calls.append("create"); return draft})
        XCTAssertEqual(calls,["check","consume","create"])
        XCTAssertEqual(result,draft)
    }
    func testExpiredCreationStopsBeforeNativeAccessOrConsumption() async throws {
        let (plan,_)=try fixture()
        do {
            _ = try await MailAutomation().createDraft(plan,deadline:.distantPast,consume:{ _ in
                throw BridgeFailure("Consumption must not be reached")
            })
            XCTFail("Expired creation must stop")
        } catch { XCTAssertTrue(error.localizedDescription.contains("deadline expired"),error.localizedDescription) }
    }
    func testFailedAuthorizationOrConsumptionNeverCreates() async throws {
        let (plan,draft)=try fixture()
        for failCheck in [true,false] {
            var count=0
            do {
                _ = try await MailCompositionDispatch.perform(plan:plan,check:{if failCheck {throw BridgeFailure("Revoked")}},consume:{throw BridgeFailure("Already attempted")},create:{count += 1; return draft})
                XCTFail("Creation must not proceed")
            } catch {}
            XCTAssertEqual(count,0)
        }
    }
    func testUncertainCreationAndDifferentReadbackDoNotRetry() async throws {
        let (plan,draft)=try fixture()
        for returnChanged in [true,false] {
            var count=0
            do {
                _ = try await MailCompositionDispatch.perform(plan:plan,check:{},consume:{},create:{
                    count += 1
                    if !returnChanged { throw BridgeFailure("Timed out") }
                    var changed=draft; changed.body += "signature"; return changed
                })
                XCTFail("An unconfirmed creation must be reported")
            } catch { XCTAssertTrue(error.localizedDescription.contains("will not retry")) }
            XCTAssertEqual(count,1)
        }
    }
}
