//
//  ToolIDTests.swift
//  zPDFTests
//
//  Purpose: Group-completeness tests for the tool catalog — every tool has
//  metadata, the five groups are populated in prototype order, and the
//  tool→panel mapping matches the prototype's TOOL_PANEL.
//  Note: the approved prototype lists 25 tools (not 24 as in the original
//  plan); the prototype is authoritative. Update this test if the tool
//  list changes.
//

import XCTest
@testable import zPDF

final class ToolIDTests: XCTestCase {

    func testExactlyFiveGroupsInPrototypeOrder() {
        XCTAssertEqual(ToolGroup.allCases.count, 5)
        XCTAssertEqual(ToolGroup.allCases.map(\.rawValue),
                       ["createEdit", "shareReview", "protectOptimize", "formsSignatures", "advanced"])
    }

    func testTotalToolCountMatchesPrototype() {
        XCTAssertEqual(ToolID.allCases.count, 25)
    }

    func testGroupSizesMatchPrototype() {
        XCTAssertEqual(ToolID.tools(in: .createEdit).count, 6)
        XCTAssertEqual(ToolID.tools(in: .shareReview).count, 4)
        XCTAssertEqual(ToolID.tools(in: .protectOptimize).count, 4)
        XCTAssertEqual(ToolID.tools(in: .formsSignatures).count, 3)
        XCTAssertEqual(ToolID.tools(in: .advanced).count, 8)
    }

    func testEveryToolHasNonEmptyMetadata() {
        for tool in ToolID.allCases {
            XCTAssertFalse(tool.name.isEmpty, "\(tool) missing name")
            XCTAssertFalse(tool.toolDescription.isEmpty, "\(tool) missing description")
            XCTAssertFalse(tool.symbolName.isEmpty, "\(tool) missing symbol")
        }
    }

    func testToolIDsAreUnique() {
        XCTAssertEqual(Set(ToolID.allCases.map(\.rawValue)).count, ToolID.allCases.count)
    }

    func testGroupTitlesMatchPrototype() {
        XCTAssertEqual(ToolGroup.createEdit.title, "Create & Edit")
        XCTAssertEqual(ToolGroup.shareReview.title, "Share & Review")
        XCTAssertEqual(ToolGroup.protectOptimize.title, "Protect & Optimize")
        XCTAssertEqual(ToolGroup.formsSignatures.title, "Forms & Signatures")
        XCTAssertEqual(ToolGroup.advanced.title, "Advanced")
    }

    func testToolToPanelMappingMatchesPrototype() {
        XCTAssertEqual(ToolID.editPDF.inspectorPanel, .edit)
        XCTAssertEqual(ToolID.comment.inspectorPanel, .comment)
        XCTAssertEqual(ToolID.fillAndSign.inspectorPanel, .fillSign)
        XCTAssertEqual(ToolID.protect.inspectorPanel, .protect)
        XCTAssertEqual(ToolID.exportPDF.inspectorPanel, .export)
        XCTAssertEqual(ToolID.organizePages.inspectorPanel, .organize)
        XCTAssertEqual(ToolID.prepareForm.inspectorPanel, .prepareForm)
        // Tools without a panel in the prototype map to nil.
        XCTAssertEqual(ToolID.redact.inspectorPanel, .redact)
        XCTAssertNil(ToolID.share.inspectorPanel)
    }

    func testToolbarShowsSupportedWorkflows() {
        // Core workflows lead; every implemented tool with a panel follows.
        XCTAssertEqual(Array(InspectorPanel.toolbarOrder.prefix(4)), [.comment, .fillSign, .organize, .export])
        for tool in ToolID.available {
            if let panel = tool.inspectorPanel { XCTAssertTrue(InspectorPanel.toolbarOrder.contains(panel), "\(tool)") }
        }
    }
}
