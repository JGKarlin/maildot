import XCTest
@testable import BridgeCore

/// Google Calendar and iCloud Calendar in Settings and in setup (owner approval, 26 November 2026).
final class CalendarConnectorTests: XCTestCase {
    private let gmail="owner@gmail.example.invalid", iCloud="owner@icloud.example.invalid"

    private func ask(_ provider:MailCalendarConnection.Provider,_ email:String,_ settings:inout MailSettings) throws -> MailSettingsRequest {
        var input=MailSettingsInput(); input.provider=provider.activation
        return try MailSettingsCoordinator.request(.activate,email:email,instruction:"Confirm the calendar connector.",input:input,settings:&settings)
    }

    func testDotConfirmsACalendarWithoutAnyAccount() throws {
        var settings=MailSettings()
        XCTAssertEqual(settings.calendarState(.google,email:gmail),.connect(failure:nil))
        let request=try ask(.google,gmail,&settings)
        XCTAssertEqual(settings.calendarState(.google,email:gmail),.checking)
        XCTAssertNil(request.expectedProfileID)
        try MailSettingsCoordinator.report(requestID:request.id,expectedRevision:settings.revision,connections:[],schedules:[],outcome:"Connected.",settings:&settings)
        XCTAssertEqual(settings.calendarState(.google,email:gmail),.connected)
        XCTAssertTrue(settings.connections.isEmpty,"a calendar is no mail account")
        XCTAssertEqual(settings.calendars?.map(\.provider),[.google])
    }

    func testACalendarConfirmationCarriesNoAccounts() throws {
        var settings=MailSettings()
        let request=try ask(.icloud,iCloud,&settings)
        var mail=MailConnection(id:"x",email:iCloud,connectionID:"c"); mail.provider="icloud"
        XCTAssertThrowsError(try MailSettingsCoordinator.report(requestID:request.id,expectedRevision:settings.revision,connections:[mail],schedules:[],outcome:"",settings:&settings))
    }

    func testAFailedCheckOffersConnectAgainWithDotsReason() throws {
        var settings=MailSettings()
        let request=try ask(.icloud,iCloud,&settings)
        let index=settings.requests.firstIndex{ $0.id == request.id }!
        settings.requests[index].status = .failed; settings.requests[index].outcome="The iCloud Calendar connector is not connected."
        XCTAssertEqual(settings.calendarState(.icloud,email:iCloud),.connect(failure:"The iCloud Calendar connector is not connected."))
    }

    func testAGmailAccountAndItsCalendarAreSeparateRequests() throws {
        var settings=MailSettings()
        _ = try ask(.google,gmail,&settings)
        XCTAssertNil(settings.latestActivation(provider:"gmail",email:gmail),"the mail row does not read the calendar's request")
        XCTAssertEqual(settings.configurationRequests(for:.accounts).count,1)
        _ = try MailSettingsCoordinator.request(.activate,email:gmail,instruction:"Connect Gmail.",settings:&settings)
        XCTAssertEqual(settings.configurationRequests(for:.accounts).count,2,"both controls keep their own request")
    }

    func testOffersListEachGmailCalendarAndOneICloudCalendar() {
        let offers=MailSettings().calendarOffers(gmail:[gmail,"Owner@Gmail.example.invalid","second@gmail.example.invalid"],iCloud:[iCloud,"other@icloud.example.invalid"])
        XCTAssertEqual(offers.map(\.provider),[.google,.google,.icloud])
        XCTAssertEqual(offers.map(\.email),[gmail,"second@gmail.example.invalid",iCloud])
    }

    func testSettingsSavedBeforeCalendarsStillLoad() throws {
        let saved=try JSONEncoder().encode(MailSettings())
        var json=try JSONSerialization.jsonObject(with:saved) as! [String:Any]
        json.removeValue(forKey:"calendars")
        let decoded=try JSONDecoder().decode(MailSettings.self,from:JSONSerialization.data(withJSONObject:json))
        XCTAssertNil(decoded.calendars)
    }
}
