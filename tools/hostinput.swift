// hostinput.swift — host-side test driver: synthesizes macOS mouse/keyboard events into the SimRun viewer window
// (exercises viewer.m -> sr_input_msg_t -> the hid module's receiver -> UIKit). Coordinates are sim scene points (viewer
// content view is 1:1 with scene points, origin top-left).
// usage: swift hostinput.swift <viewer-pid> cmd [cmd...]      (HOSTINPUT_TITLE=<window title> picks one of several windows)
//   click X Y | drag X0 Y0 X1 Y1 | type TEXT | key KEYCODE [FLAGS] | wait SECS
import CoreGraphics
import Foundation

let args = CommandLine.arguments
guard args.count > 2, let pid = pid_t(args[1]) else {
  print("usage: hostinput <pid> cmds...")
  exit(2)
}

func viewerContentOrigin() -> CGPoint {
  let l = (CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]]) ?? []
  let title = ProcessInfo.processInfo.environment["HOSTINPUT_TITLE"]
  let ws = l.filter { ($0["kCGWindowOwnerPID"] as? Int) == Int(pid) && ($0["kCGWindowLayer"] as? Int) == 0 &&
                      ((($0["kCGWindowBounds"] as? [String: Double])?["Height"] ?? 0) > 100) &&
                      (title == nil || ($0["kCGWindowName"] as? String) == title) }
  guard let w = ws.first, let b = w["kCGWindowBounds"] as? [String: Double] else {
    print("no viewer window")
    exit(1)
  }
  let titleBar = b["Height"]! - 874  // content view is 874 pt tall
  return CGPoint(x: b["X"]!, y: b["Y"]! + titleBar)
}
let origin = viewerContentOrigin()
func P(_ x: Double, _ y: Double) -> CGPoint {
  CGPoint(x: origin.x + x, y: origin.y + y)
}
let src = CGEventSource(stateID: .hidSystemState)
let global = ProcessInfo.processInfo.environment["HOSTINPUT_PID_ONLY"] == nil  // default: post at the HID tap (needs Accessibility permission)
func post(_ e: CGEvent) {
  if global {
    e.post(tap: .cghidEventTap)
  } else {
    e.postToPid(pid)
  }
}
func mouse(_ t: CGEventType, _ p: CGPoint) {
  let e = CGEvent(mouseEventSource: src, mouseType: t, mouseCursorPosition: p, mouseButton: .left)!
  post(e)
}
func key(_ code: CGKeyCode, _ down: Bool, _ flags: CGEventFlags = [], _ text: String? = nil) {
  let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down)!
  e.flags = flags
  if let t = text {
    let u = Array(t.utf16)
    e.keyboardSetUnicodeString(stringLength: u.count, unicodeString: u)
  }
  post(e)
}
// US layout: character -> (keycode, shift)
let usKeys: [Character: (CGKeyCode, Bool)] = {
  var m: [Character: (CGKeyCode, Bool)] = [:]
  let letters: [(Character, CGKeyCode)] = [("a",0),("s",1),("d",2),("f",3),("h",4),("g",5),("z",6),("x",7),("c",8),("v",9),("b",11),("q",12),("w",13),("e",14),("r",15),("y",16),("t",17),("o",31),("u",32),("i",34),("p",35),("l",37),("j",38),("k",40),("n",45),("m",46)]
  for (c, k) in letters {
    m[c] = (k, false)
    m[Character(c.uppercased())] = (k, true)
  }
  let others: [(Character, CGKeyCode, Bool)] = [("1",18,false),("2",19,false),("3",20,false),("4",21,false),("5",23,false),("6",22,false),("7",26,false),("8",28,false),("9",25,false),("0",29,false),(" ",49,false),("!",18,true),(",",43,false),(".",47,false),("-",27,false),("?",44,true)]
  for (c, k, s) in others {
    m[c] = (k, s)
  }
  return m
}()

var i = 2
func num(_ k: Int) -> Double {
  Double(args[i + k])!
}
while i < args.count {
  switch args[i] {
  case "click":
    let p = P(num(1), num(2))
    mouse(.leftMouseDown, p)
    usleep(60_000)
    mouse(.leftMouseUp, p)
    i += 3
  case "drag":
    let a = P(num(1), num(2)), b = P(num(3), num(4))
    mouse(.leftMouseDown, a)
    for s in 1...20 {
      usleep(15_000)
      let t = Double(s) / 20
      mouse(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
    }
    mouse(.leftMouseUp, b)
    i += 5
  case "type":
    for c in args[i + 1] {
      guard let (k, shift) = usKeys[c] else {
        continue
      }
      let f: CGEventFlags = shift ? .maskShift : []
      key(k, true, f, String(c))
      usleep(30_000)
      key(k, false, f, String(c))
      usleep(30_000)
    }
    i += 2
  case "key":
    let k = CGKeyCode(UInt16(args[i + 1], radix: 16) ?? UInt16(args[i + 1])!)
    var f: CGEventFlags = []
    var n = 2
    if i + 2 < args.count, let fl = UInt64(args[i + 2].replacingOccurrences(of: "0x", with: ""), radix: 16), args[i + 2].hasPrefix("0x") {
      f = CGEventFlags(rawValue: fl)
      n = 3
    }
    key(k, true, f)
    usleep(40_000)
    key(k, false, f)
    i += n
  case "wait":
    usleep(useconds_t(num(1) * 1_000_000))
    i += 2
  default:
    print("unknown \(args[i])")
    exit(2)
  }
  usleep(150_000)
}
