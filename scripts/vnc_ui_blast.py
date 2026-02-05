#!/usr/bin/env python3
import argparse
import itertools
import time
import tkinter as tk


def main():
    parser = argparse.ArgumentParser(description="Fullscreen UI blast for VNC tests")
    parser.add_argument("--interval", type=float, default=0.5, help="seconds between flips")
    args = parser.parse_args()

    root = tk.Tk()
    root.title("VNC Blast")
    root.attributes("-fullscreen", True)
    root.configure(background="black")
    label = tk.Label(
        root,
        text="",
        font=("Helvetica", 48),
        fg="white",
        bg="black",
    )
    label.pack(expand=True)

    colors = itertools.cycle([("black", "white"), ("white", "black")])

    def flip():
        bg, fg = next(colors)
        root.configure(background=bg)
        label.configure(background=bg, foreground=fg)
        label.configure(text=time.strftime("%H:%M:%S"))
        root.after(int(args.interval * 1000), flip)

    root.bind("<Escape>", lambda _evt: root.destroy())
    flip()
    root.mainloop()


if __name__ == "__main__":
    main()
