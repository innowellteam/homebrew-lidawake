import AppKit

// The About panel's credits: the innowell wordmark, a line of thanks and a link to innowell.org.
// The wordmark is dark teal on a light panel and sand on a dark one, the two colourways the brand
// allows, with clear space below it of its own height, the minimum the brand asks for.
func aboutCredits(bundle: Bundle = .main) -> NSAttributedString {
    let light = bundle.image(forResource: "innowell-logo")!
    let dark = bundle.image(forResource: "innowell-logo-sand")!
    let width: CGFloat = 112
    let height = (width * light.size.height / light.size.width).rounded()
    // Drawn on demand, so it picks the right file for the panel's appearance, and again if that changes.
    let logo = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
        let image = NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        // The two files differ slightly in shape, so fit each one rather than stretch it.
        let scale = min(rect.width / image.size.width, rect.height / image.size.height)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        image.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height))
        return true
    }
    let attachment = NSTextAttachment()
    attachment.image = logo

    func paragraph(spacingAfter: CGFloat) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.paragraphSpacing = spacingAfter
        return style
    }
    let small = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
    let credits = NSMutableAttributedString(attachment: attachment)
    credits.addAttribute(.paragraphStyle, value: paragraph(spacingAfter: height), range: NSRange(location: 0, length: credits.length))
    credits.append(NSAttributedString(string: "\nMade with love at innowell\n", attributes: [
        .font: small,
        .foregroundColor: NSColor.secondaryLabelColor,
        .paragraphStyle: paragraph(spacingAfter: 2),
    ]))
    credits.append(NSAttributedString(string: "innowell.org", attributes: [
        .font: small,
        .link: URL(string: "https://innowell.org")!,
        .paragraphStyle: paragraph(spacingAfter: 0),
    ]))
    return credits
}
