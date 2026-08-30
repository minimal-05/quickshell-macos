#!/usr/bin/python3
import ctypes, ctypes.util, sys, time
cg = ctypes.CDLL(ctypes.util.find_library("CoreGraphics") or
                 "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")
class CGPoint(ctypes.Structure):
    _fields_ = [("x", ctypes.c_double), ("y", ctypes.c_double)]
kCGEventMouseMoved = 5
kCGHIDEventTap = 0
cg.CGEventCreateMouseEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint32, CGPoint, ctypes.c_uint32]
cg.CGEventCreateMouseEvent.restype = ctypes.c_void_p
cg.CGEventPost.argtypes = [ctypes.c_uint32, ctypes.c_void_p]
cg.CFRelease.argtypes = [ctypes.c_void_p]

def move(x, y):
    # A real mouse-moved event, not CGWarpMouseCursorPosition: the warp relocates
    # the cursor without telling anyone, so Qt never sees enter/leave.
    ev = cg.CGEventCreateMouseEvent(None, kCGEventMouseMoved, CGPoint(x, y), 0)
    cg.CGEventPost(kCGHIDEventTap, ev)
    cg.CFRelease(ev)

x, y = float(sys.argv[1]), float(sys.argv[2])
# nudge first so a move is always registered even if already at the target
move(x + 3, y + 3); time.sleep(0.03)
move(x, y)
print(f"  moved to {x},{y}")
