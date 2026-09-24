//
//  PowerPointExporter.swift
//  zPDF
//
//  Purpose: PDF → .pptx export used by BasicExportService. One slide per
//  page; each slide carries the page's text in a full-slide text box
//  (partial fidelity is explicitly fine). Emits minimal valid
//  PresentationML (presentation + one master + one blank layout + theme)
//  packed with OOXMLZip from OOXML.swift.
//  Phase: 4 — implemented.
//

import AppKit
import Foundation
import PDFKit

enum PowerPointExporter {
    /// EMU (English Metric Units) per point — slide geometry unit.
    private static let emuPerPoint: Double = 12700

    @MainActor static func export(document: EngineDocument, to destination: URL, engine: any PDFEngine) throws {
        let pageCount = engine.pageCount(of: document)
        guard pageCount > 0, let firstPage = engine.page(at: 0, in: document) else {
            throw ExportError.nothingToExport
        }

        let pageBounds = firstPage.bounds(for: .mediaBox)
        let slideWidth = Int(pageBounds.width * emuPerPoint)
        let slideHeight = Int(pageBounds.height * emuPerPoint)

        var slideTexts: [String] = []
        for index in 0..<pageCount {
            guard let page = engine.page(at: index, in: document) else { continue }
            slideTexts.append(page.string ?? "")
        }
        guard slideTexts.contains(where: {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else {
            throw ExportError.nothingToExport
        }

        var entries = [
            OOXMLZip.Entry(name: "[Content_Types].xml", data: Data(contentTypesXML(slideCount: slideTexts.count).utf8)),
            OOXMLZip.Entry(name: "_rels/.rels", data: Data(rootRelsXML.utf8)),
            OOXMLZip.Entry(name: "ppt/presentation.xml", data: Data(presentationXML(slideCount: slideTexts.count, width: slideWidth, height: slideHeight).utf8)),
            OOXMLZip.Entry(name: "ppt/_rels/presentation.xml.rels", data: Data(presentationRelsXML(slideCount: slideTexts.count).utf8)),
            OOXMLZip.Entry(name: "ppt/slideMasters/slideMaster1.xml", data: Data(slideMasterXML.utf8)),
            OOXMLZip.Entry(name: "ppt/slideMasters/_rels/slideMaster1.xml.rels", data: Data(slideMasterRelsXML.utf8)),
            OOXMLZip.Entry(name: "ppt/slideLayouts/slideLayout1.xml", data: Data(slideLayoutXML.utf8)),
            OOXMLZip.Entry(name: "ppt/slideLayouts/_rels/slideLayout1.xml.rels", data: Data(slideLayoutRelsXML.utf8)),
            OOXMLZip.Entry(name: "ppt/theme/theme1.xml", data: Data(themeXML.utf8)),
        ]
        for (index, text) in slideTexts.enumerated() {
            let number = index + 1
            entries.append(OOXMLZip.Entry(
                name: "ppt/slides/slide\(number).xml",
                data: Data(slideXML(text: text, pageIndex: index, width: slideWidth, height: slideHeight).utf8)))
            entries.append(OOXMLZip.Entry(
                name: "ppt/slides/_rels/slide\(number).xml.rels",
                data: Data(slideRelsXML.utf8)))
        }
        try OOXMLZip.write(entries: entries, to: destination)
    }

    // MARK: - PresentationML parts

    private static func contentTypesXML(slideCount: Int) -> String {
        var xml = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
            <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
            <Default Extension="xml" ContentType="application/xml"/>\
            <Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/>\
            <Override PartName="/ppt/slideMasters/slideMaster1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml"/>\
            <Override PartName="/ppt/slideLayouts/slideLayout1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml"/>\
            <Override PartName="/ppt/theme/theme1.xml" ContentType="application/vnd.openxmlformats-officedocument.theme+xml"/>

            """
        for number in 1...slideCount {
            xml += "<Override PartName=\"/ppt/slides/slide\(number).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slide+xml\"/>"
        }
        return xml + "</Types>"
    }

    private static let rootRelsXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="ppt/presentation.xml"/>\
        </Relationships>
        """

    private static func presentationXML(slideCount: Int, width: Int, height: Int) -> String {
        var xml = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <p:presentation xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">\
            <p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst>\
            <p:sldIdLst>

            """
        for number in 1...slideCount {
            xml += "<p:sldId id=\"\(255 + number)\" r:id=\"rId\(number + 1)\"/>"
        }
        xml += "</p:sldIdLst>"
        xml += "<p:sldSz cx=\"\(width)\" cy=\"\(height)\"/><p:notesSz cx=\"6858000\" cy=\"9144000\"/>"
        return xml + "</p:presentation>"
    }

    private static func presentationRelsXML(slideCount: Int) -> String {
        var xml = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="slideMasters/slideMaster1.xml"/>

            """
        for number in 1...slideCount {
            xml += "<Relationship Id=\"rId\(number + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide\" Target=\"slides/slide\(number).xml\"/>"
        }
        return xml + "</Relationships>"
    }

    private static let slideMasterXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:sldMaster xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">\
        <p:cSld><p:spTree>\
        <p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>\
        <p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>\
        </p:spTree></p:cSld>\
        <p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/>\
        <p:sldLayoutIdLst><p:sldLayoutId id="2147483649" r:id="rId1"/></p:sldLayoutIdLst>\
        <p:txStyles>\
        <p:titleStyle><a:lvl1pPr><a:defRPr sz="4400"/></a:lvl1pPr></p:titleStyle>\
        <p:bodyStyle><a:lvl1pPr><a:defRPr sz="2400"/></a:lvl1pPr></p:bodyStyle>\
        <p:otherStyle><a:lvl1pPr><a:defRPr sz="1800"/></a:lvl1pPr></p:otherStyle>\
        </p:txStyles>\
        </p:sldMaster>
        """

    private static let slideMasterRelsXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>\
        <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme" Target="../theme/theme1.xml"/>\
        </Relationships>
        """

    private static let slideLayoutXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:sldLayout xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" type="blank" preserve="1">\
        <p:cSld name="Blank"><p:spTree>\
        <p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>\
        <p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>\
        </p:spTree></p:cSld>\
        <p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr>\
        </p:sldLayout>
        """

    private static let slideLayoutRelsXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="../slideMasters/slideMaster1.xml"/>\
        </Relationships>
        """

    private static let themeXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="zPDF">\
        <a:themeElements>\
        <a:clrScheme name="Office">\
        <a:dk1><a:sysClr val="windowText" lastClr="000000"/></a:dk1>\
        <a:lt1><a:sysClr val="window" lastClr="FFFFFF"/></a:lt1>\
        <a:dk2><a:srgbClr val="1F497D"/></a:dk2>\
        <a:lt2><a:srgbClr val="EEECE1"/></a:lt2>\
        <a:accent1><a:srgbClr val="4F81BD"/></a:accent1>\
        <a:accent2><a:srgbClr val="C0504D"/></a:accent2>\
        <a:accent3><a:srgbClr val="9BBB59"/></a:accent3>\
        <a:accent4><a:srgbClr val="8064A2"/></a:accent4>\
        <a:accent5><a:srgbClr val="4BACC6"/></a:accent5>\
        <a:accent6><a:srgbClr val="F79646"/></a:accent6>\
        <a:hlink><a:srgbClr val="0000FF"/></a:hlink>\
        <a:folHlink><a:srgbClr val="800080"/></a:folHlink>\
        </a:clrScheme>\
        <a:fontScheme name="Office">\
        <a:majorFont><a:latin typeface="Helvetica"/><a:ea typeface=""/><a:cs typeface=""/></a:majorFont>\
        <a:minorFont><a:latin typeface="Helvetica"/><a:ea typeface=""/><a:cs typeface=""/></a:minorFont>\
        </a:fontScheme>\
        <a:fmtScheme name="Office">\
        <a:fillStyleLst>\
        <a:solidFill><a:schemeClr val="phClr"/></a:solidFill>\
        <a:solidFill><a:schemeClr val="phClr"/></a:solidFill>\
        <a:solidFill><a:schemeClr val="phClr"/></a:solidFill>\
        </a:fillStyleLst>\
        <a:lnStyleLst>\
        <a:ln w="9525"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln>\
        <a:ln w="25400"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln>\
        <a:ln w="38100"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln>\
        </a:lnStyleLst>\
        <a:effectStyleLst>\
        <a:effectStyle><a:effectLst/></a:effectStyle>\
        <a:effectStyle><a:effectLst/></a:effectStyle>\
        <a:effectStyle><a:effectLst/></a:effectStyle>\
        </a:effectStyleLst>\
        <a:bgFillStyleLst>\
        <a:solidFill><a:schemeClr val="phClr"/></a:solidFill>\
        <a:solidFill><a:schemeClr val="phClr"/></a:solidFill>\
        <a:solidFill><a:schemeClr val="phClr"/></a:solidFill>\
        </a:bgFillStyleLst>\
        </a:fmtScheme>\
        </a:themeElements>\
        </a:theme>
        """

    /// One slide: a full-slide text box carrying the page's text, one
    /// DrawingML paragraph per text line.
    private static func slideXML(text: String, pageIndex: Int, width: Int, height: Int) -> String {
        let margin = 457200 // 0.5 in
        var paragraphs = ""
        for line in text.components(separatedBy: .newlines) {
            paragraphs += "<a:p><a:r><a:t>\(escapeXML(line))</a:t></a:r></a:p>"
        }
        if paragraphs.isEmpty { paragraphs = "<a:p/>" }
        return """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">\
            <p:cSld><p:spTree>\
            <p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>\
            <p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>\
            <p:sp>\
            <p:nvSpPr><p:cNvPr id="2" name="Page \(pageIndex + 1) text"/><p:cNvSpPr txBox="1"/><p:nvPr/></p:nvSpPr>\
            <p:spPr><a:xfrm><a:off x="\(margin)" y="\(margin)"/><a:ext cx="\(width - 2 * margin)" cy="\(height - 2 * margin)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr>\
            <p:txBody><a:bodyPr wrap="square"><a:normAutofit/></a:bodyPr><a:lstStyle/>\(paragraphs)</p:txBody>\
            </p:sp>\
            </p:spTree></p:cSld>\
            <p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr>\
            </p:sld>
            """
    }

    private static let slideRelsXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>\
        </Relationships>
        """

    private static func escapeXML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
