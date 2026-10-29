import CoreGraphics
import Foundation
// Prints "<window id> <width>x<height> <name>" for each on-screen window of the pid given.
let pid = Int32(CommandLine.arguments[1])!
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
for w in list where (w[kCGWindowOwnerPID as String] as? Int32) == pid && (w[kCGWindowLayer as String] as? Int) == 0 {
    let b = w[kCGWindowBounds as String] as! [String: Any]
    print(w[kCGWindowNumber as String]!, "\(b["Width"]!)x\(b["Height"]!)", w[kCGWindowName as String] ?? "")
}
