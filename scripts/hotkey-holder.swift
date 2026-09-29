// Holds a global shortcut exclusively for a while, as another app can: the `firstrun`
// scenario's other app (PRD SC2), to show Nib saying the keys are taken.
//   hotkey-holder <keyCode> <carbon modifiers> <seconds>
// Prints "held" once it has them, or "not held <status>".

import Carbon.HIToolbox
import Foundation

let arguments = CommandLine.arguments.dropFirst().compactMap { UInt32($0) }
guard arguments.count == 3 else { print("usage: hotkey-holder <keyCode> <modifiers> <seconds>"); exit(2) }
var reference: EventHotKeyRef?
let status = RegisterEventHotKey(arguments[0], arguments[1], EventHotKeyID(signature: 0x686F_6C64, id: 1),   // 'hold'
                                 GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &reference)
print(status == noErr ? "held" : "not held \(status)")
fflush(stdout)
guard status == noErr else { exit(1) }
RunLoop.main.run(until: Date().addingTimeInterval(TimeInterval(arguments[2])))
