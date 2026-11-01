#!/usr/bin/env python3
"""Exit 0 when the X display has a viewable window whose title matches.

usage: find-window.py <title regex>

The Flatpak builder image has no xdotool, but it has Python and libX11, so
this does what `xdotool search --onlyvisible --name <regex>` does: walk the
window tree, read WM_NAME and _NET_WM_NAME, and check the map state.
"""
import ctypes
import re
import sys

x11 = ctypes.CDLL("libX11.so.6")
Display = ctypes.c_void_p
Window = ctypes.c_ulong
Atom = ctypes.c_ulong


class XWindowAttributes(ctypes.Structure):
    _fields_ = [
        ("x", ctypes.c_int), ("y", ctypes.c_int),
        ("width", ctypes.c_int), ("height", ctypes.c_int),
        ("border_width", ctypes.c_int), ("depth", ctypes.c_int),
        ("visual", ctypes.c_void_p), ("root", Window),
        ("class_", ctypes.c_int), ("bit_gravity", ctypes.c_int),
        ("win_gravity", ctypes.c_int), ("backing_store", ctypes.c_int),
        ("backing_planes", ctypes.c_ulong), ("backing_pixel", ctypes.c_ulong),
        ("save_under", ctypes.c_int), ("colormap", ctypes.c_ulong),
        ("map_installed", ctypes.c_int), ("map_state", ctypes.c_int),
        ("all_event_masks", ctypes.c_long), ("your_event_mask", ctypes.c_long),
        ("do_not_propagate_mask", ctypes.c_long),
        ("override_redirect", ctypes.c_int), ("screen", ctypes.c_void_p),
    ]


IS_VIEWABLE = 2
ERROR_HANDLER = ctypes.CFUNCTYPE(ctypes.c_int, Display, ctypes.c_void_p)

x11.XOpenDisplay.restype = Display
x11.XOpenDisplay.argtypes = [ctypes.c_char_p]
x11.XDefaultRootWindow.restype = Window
x11.XDefaultRootWindow.argtypes = [Display]
x11.XInternAtom.restype = Atom
x11.XInternAtom.argtypes = [Display, ctypes.c_char_p, ctypes.c_int]
x11.XQueryTree.argtypes = [
    Display, Window, ctypes.POINTER(Window), ctypes.POINTER(Window),
    ctypes.POINTER(ctypes.POINTER(Window)), ctypes.POINTER(ctypes.c_uint)]
x11.XGetWindowAttributes.argtypes = [
    Display, Window, ctypes.POINTER(XWindowAttributes)]
x11.XGetWindowProperty.argtypes = [
    Display, Window, Atom, ctypes.c_long, ctypes.c_long, ctypes.c_int, Atom,
    ctypes.POINTER(Atom), ctypes.POINTER(ctypes.c_int),
    ctypes.POINTER(ctypes.c_ulong), ctypes.POINTER(ctypes.c_ulong),
    ctypes.POINTER(ctypes.c_void_p)]
x11.XFree.argtypes = [ctypes.c_void_p]
x11.XSetErrorHandler.argtypes = [ERROR_HANDLER]


def main():
    pattern = re.compile(sys.argv[1])
    display = x11.XOpenDisplay(None)
    if not display:
        sys.exit("cannot open the X display")
    # Windows can vanish between listing and reading them; ignore the errors
    # instead of letting Xlib's default handler exit.
    handler = ERROR_HANDLER(lambda _d, _e: 0)
    x11.XSetErrorHandler(handler)
    any_property_type = Atom(0)
    names = [x11.XInternAtom(display, b"_NET_WM_NAME", 0),
             x11.XInternAtom(display, b"WM_NAME", 0)]

    def titles(window):
        for atom in names:
            actual, fmt = Atom(), ctypes.c_int()
            count, after = ctypes.c_ulong(), ctypes.c_ulong()
            data = ctypes.c_void_p()
            if x11.XGetWindowProperty(
                    display, window, atom, 0, 1024, 0, any_property_type,
                    ctypes.byref(actual), ctypes.byref(fmt), ctypes.byref(count),
                    ctypes.byref(after), ctypes.byref(data)) == 0 and data.value:
                if fmt.value == 8:
                    yield ctypes.string_at(data, count.value).decode("utf-8", "replace")
                x11.XFree(data)

    def walk(window):
        root, parent = Window(), Window()
        children, n = ctypes.POINTER(Window)(), ctypes.c_uint()
        if not x11.XQueryTree(display, window, ctypes.byref(root),
                              ctypes.byref(parent), ctypes.byref(children),
                              ctypes.byref(n)):
            return
        kids = [children[i] for i in range(n.value)]
        if children:
            x11.XFree(children)
        for kid in kids:
            yield kid
            yield from walk(kid)

    for window in walk(x11.XDefaultRootWindow(display)):
        attrs = XWindowAttributes()
        if not x11.XGetWindowAttributes(display, window, ctypes.byref(attrs)):
            continue
        if attrs.map_state != IS_VIEWABLE:
            continue
        for title in titles(window):
            if pattern.search(title):
                print(f"window 0x{window:x}: {title!r}")
                return 0
    return 1


if __name__ == "__main__":
    sys.exit(main())
