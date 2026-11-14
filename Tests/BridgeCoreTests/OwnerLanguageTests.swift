import XCTest
@testable import BridgeCore

final class OwnerLanguageTests:XCTestCase {
    func testTheInterfaceLanguageFollowsTheMacsPreferredLanguages() {
        XCTAssertEqual(OwnerLanguage.code(preferences:["en-JP","ja-JP"]),"en")
        XCTAssertEqual(OwnerLanguage.code(preferences:["ja-JP","en-US"]),"ja")
        XCTAssertEqual(OwnerLanguage.code(preferences:["sw-KE","ja-JP"]),"ja","the first preferred language Mail Dot is translated into")
        XCTAssertEqual(OwnerLanguage.code(preferences:["sw-KE"]),"en","English when none is")
        XCTAssertEqual(OwnerLanguage.code(preferences:["fr-FR"]),"fr")
        XCTAssertEqual(OwnerLanguage.code(preferences:["zh-Hant-TW"]),"zh-Hant")
        XCTAssertEqual(OwnerLanguage.code(preferences:["pt-BR"]),"pt-BR")
        XCTAssertEqual(OwnerLanguage.code(preferences:["es-MX"]),"es-419")
        XCTAssertEqual(OwnerLanguage.code(preferences:["nb-NO"]),"nb")
        XCTAssertEqual(OwnerLanguage.name(code:"zh-Hans"),"Chinese, Simplified")
    }

    func testDotIsToldToReplyInTheMessagesLanguageAndToWriteEverythingElseInTheMacs() throws {
        var context=ReplyContext(id:"reply",envelope:MailDraft(id: -1,subject:"Re: test",sender:"owner@example.invalid",to:[],cc:[],bcc:[],body:"",attachmentCount:0))
        BridgeCoordinator.ownerOpensPanel(context:&context)
        let english=try XCTUnwrap(BridgeCoordinator.instruction(for:context,preferences:["en-US"]))
        XCTAssertTrue(english.contains("write the reply itself in the language of the message it answers"))
        XCTAssertTrue(english.contains("in English, the language of the owner's Mac"))
        let japanese=try XCTUnwrap(BridgeCoordinator.instruction(for:context,preferences:["ja-JP"]))
        XCTAssertTrue(japanese.contains("in Japanese, the language of the owner's Mac"))
        context.ownerRequest?.ignored=true
        XCTAssertTrue(try XCTUnwrap(BridgeCoordinator.instruction(for:context,preferences:["en-US"])).contains("in English"),"also when the message is set aside, since Dot still writes a status")
    }
}
