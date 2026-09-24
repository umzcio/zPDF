//
//  DocumentTabTests.swift
//  zPDFTests
//
//  Purpose: Tab-model basics — defaults, display name, page navigation
//  clamping (against a real PDFDocument), zoom clamping, and view-mode
//  mapping onto PDFKit display modes. Also covers phase-3 AcroForm
//  filling: enumerating fillable widget fields and setting values
//  through PDFEngine round-trips into the document's widget annotations.
//

import PDFKit
import XCTest
@testable import zPDF

final class DocumentTabTests: XCTestCase {

    private func makeTab(pageCount: Int = 3) -> DocumentTab {
        let document = PDFDocument()
        for index in 0..<pageCount {
            document.insert(PDFPage(), at: index)
        }
        return DocumentTab(url: URL(fileURLWithPath: "/tmp/Quarterly-Report.pdf"),
                           pdfDocument: document)
    }

    func testDefaults() {
        let tab = DocumentTab()
        XCTAssertEqual(tab.currentPage, 1)
        XCTAssertEqual(tab.zoomFactor, 1.0)
        XCTAssertEqual(tab.viewMode, .single)
        XCTAssertEqual(tab.rotationDegrees, 0)
        XCTAssertEqual(tab.pageCount, 0)
        XCTAssertEqual(tab.displayName, "Untitled.pdf")
    }

    func testDisplayNameComesFromURL() {
        XCTAssertEqual(makeTab().displayName, "Quarterly-Report.pdf")
    }

    func testPageNavigationClampsToDocumentRange() {
        let tab = makeTab(pageCount: 3)
        tab.goToPage(2)
        XCTAssertEqual(tab.currentPage, 2)
        tab.goToNextPage()
        tab.goToNextPage() // would be 4 — clamps to 3
        XCTAssertEqual(tab.currentPage, 3)
        tab.goToPage(0) // clamps to 1
        XCTAssertEqual(tab.currentPage, 1)
        tab.goToPreviousPage()
        XCTAssertEqual(tab.currentPage, 1)
    }

    func testZoomClampsToBounds() {
        let tab = makeTab()
        tab.setZoom(3.0)
        XCTAssertEqual(tab.zoomFactor, 2.0)
        tab.setZoom(0.1)
        XCTAssertEqual(tab.zoomFactor, 0.5)
        tab.setZoom(1.25)
        XCTAssertEqual(tab.zoomFactor, 1.25)
    }

    func testSteppedZoomFollowsPrototypeStops() {
        XCTAssertEqual(ZoomController.steppedZoom(from: 1.0, direction: .in), 1.10)
        XCTAssertEqual(ZoomController.steppedZoom(from: 1.0, direction: .out), 0.90)
        XCTAssertEqual(ZoomController.steppedZoom(from: 2.0, direction: .in), 2.0)
        XCTAssertEqual(ZoomController.steppedZoom(from: 0.5, direction: .out), 0.5)
    }

    func testViewModeMapsToPDFDisplayMode() {
        XCTAssertEqual(PDFViewMode.single.pdfDisplayMode, .singlePage)
        XCTAssertEqual(PDFViewMode.continuous.pdfDisplayMode, .singlePageContinuous)
        XCTAssertEqual(PDFViewMode.facing.pdfDisplayMode, .twoUp)
    }

    func testPercentString() {
        XCTAssertEqual(ZoomController.percentString(1.0), "100%")
        XCTAssertEqual(ZoomController.percentString(0.675), "68%")
    }

    // MARK: - AcroForm filling (phase 3)

    /// Build a one-page document with a text, checkbox, and choice widget,
    /// plus a non-widget annotation that must be ignored.
    private func makeFormDocument() -> (EngineDocument, PDFKitEngine) {
        let engine = PDFKitEngine()
        let document = engine.createEmptyDocument()
        document.insert(PDFPage(), at: 0)
        let page = document.page(at: 0)!

        let text = PDFAnnotation(bounds: CGRect(x: 50, y: 700, width: 200, height: 22),
                                 forType: .widget, withProperties: nil)
        text.widgetFieldType = .text
        text.fieldName = "applicantName"
        page.addAnnotation(text)

        let checkbox = PDFAnnotation(bounds: CGRect(x: 50, y: 660, width: 16, height: 16),
                                     forType: .widget, withProperties: nil)
        checkbox.widgetFieldType = .button
        checkbox.widgetControlType = .checkBoxControl
        checkbox.buttonWidgetStateString = "Yes"
        checkbox.fieldName = "agreesToTerms"
        page.addAnnotation(checkbox)

        let dropdown = PDFAnnotation(bounds: CGRect(x: 50, y: 610, width: 120, height: 22),
                                     forType: .widget, withProperties: nil)
        dropdown.widgetFieldType = .choice
        dropdown.choices = ["Basic", "Pro", "Team"]
        dropdown.fieldName = "plan"
        page.addAnnotation(dropdown)

        let highlight = PDFAnnotation(bounds: CGRect(x: 50, y: 500, width: 100, height: 14),
                                      forType: .highlight, withProperties: nil)
        page.addAnnotation(highlight)

        return (document, engine)
    }

    func testFormFieldsEnumeratesFillableWidgets() {
        let (document, engine) = makeFormDocument()
        let fields = engine.formFields(in: document)

        XCTAssertEqual(fields.map(\.name), ["applicantName", "agreesToTerms", "plan"])
        XCTAssertEqual(fields.map(\.kind), [.text, .checkbox, .choice])
        XCTAssertEqual(fields.map(\.pageIndex), [0, 0, 0])
        XCTAssertEqual(fields[0].value, "")
        XCTAssertEqual(fields[1].value, PDFFormField.checkboxOff)
        XCTAssertEqual(fields[2].options, ["Basic", "Pro", "Team"])
    }

    func testFormFieldsEmptyWhenNoWidgets() {
        let engine = PDFKitEngine()
        let document = engine.createEmptyDocument()
        document.insert(PDFPage(), at: 0)
        XCTAssertTrue(engine.formFields(in: document).isEmpty)
    }

    func testSetFormFieldValueRoundTrips() throws {
        let (document, engine) = makeFormDocument()

        try engine.setFormFieldValue("Ada Lovelace", forFieldNamed: "applicantName", in: document)
        try engine.setFormFieldValue(PDFFormField.checkboxOn, forFieldNamed: "agreesToTerms", in: document)
        try engine.setFormFieldValue("Pro", forFieldNamed: "plan", in: document)

        let fields = engine.formFields(in: document)
        XCTAssertEqual(fields.first { $0.name == "applicantName" }?.value, "Ada Lovelace")
        XCTAssertEqual(fields.first { $0.name == "agreesToTerms" }?.value, PDFFormField.checkboxOn)
        XCTAssertEqual(fields.first { $0.name == "plan" }?.value, "Pro")

        // The values live on the document's widget annotations themselves.
        let annotations = document.page(at: 0)!.annotations
        XCTAssertEqual(annotations.first { $0.fieldName == "applicantName" }?.widgetStringValue,
                       "Ada Lovelace")
        XCTAssertEqual(annotations.first { $0.fieldName == "agreesToTerms" }?.buttonWidgetState,
                       .onState)

        // Unchecking round-trips back to off.
        try engine.setFormFieldValue(PDFFormField.checkboxOff, forFieldNamed: "agreesToTerms", in: document)
        XCTAssertEqual(engine.formFields(in: document).first { $0.name == "agreesToTerms" }?.value,
                       PDFFormField.checkboxOff)
    }

    func testSetFormFieldValueThrowsForUnknownField() {
        let (document, engine) = makeFormDocument()
        XCTAssertThrowsError(try engine.setFormFieldValue("x", forFieldNamed: "nope", in: document)) { error in
            guard case PDFEngineError.formFieldNotFound(let name) = error else {
                return XCTFail("Expected formFieldNotFound, got \(error)")
            }
            XCTAssertEqual(name, "nope")
        }
    }

    func testFormFieldValuesSurviveSaveAndReload() throws {
        let (document, engine) = makeFormDocument()
        try engine.setFormFieldValue("Ada Lovelace", forFieldNamed: "applicantName", in: document)
        try engine.setFormFieldValue(PDFFormField.checkboxOn, forFieldNamed: "agreesToTerms", in: document)
        try engine.setFormFieldValue("Team", forFieldNamed: "plan", in: document)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        try engine.save(document, to: url)

        let reloaded = try engine.openDocument(at: url)
        let fields = engine.formFields(in: reloaded)
        XCTAssertEqual(fields.first { $0.name == "applicantName" }?.value, "Ada Lovelace")
        XCTAssertEqual(fields.first { $0.name == "agreesToTerms" }?.value, PDFFormField.checkboxOn)
        XCTAssertEqual(fields.first { $0.name == "plan" }?.value, "Team")
    }
}
