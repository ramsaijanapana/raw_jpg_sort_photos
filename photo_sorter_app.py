#!/usr/bin/env python3
"""Photo Sorter — organise RAW and JPG files into separate folders."""

import threading
import shutil
from pathlib import Path

import customtkinter as ctk
from tkinter import filedialog

ctk.set_appearance_mode("system")
ctk.set_default_color_theme("blue")

RAW_EXTENSIONS = {".arw", ".cr2", ".cr3", ".nef", ".raf", ".orf", ".dng", ".rw2", ".pef", ".srw"}
JPG_EXTENSIONS = {".jpg", ".jpeg"}

# ---------------------------------------------------------------- palette
# (light, dark) tuples — adapts to system appearance mode
BG          = ("#F4F5F7", "#15161A")
CARD        = ("#FFFFFF", "#1E2026")
CARD_INNER  = ("#F2F4F7", "#272A32")
BORDER      = ("#E3E6EB", "#32353E")
BORDER_SOFT = ("#EBEDF1", "#2A2D35")
TEXT        = ("#181A20", "#EDEEF2")
SUBTLE      = ("#7A8089", "#9AA0AB")
ACCENT      = "#4F8EF7"
ACCENT_HOV  = "#3D7DE8"
GREEN       = ("#15803D", "#4ADE80")
GREEN_BG    = ("#EAF7EF", "#1B2B22")
RED         = ("#C92A2A", "#F87171")
RED_BG      = ("#FBEDED", "#2C1D1F")
AMBER       = ("#B45309", "#FBBF24")


class PhotoSorterApp(ctk.CTk):
    def __init__(self):
        super().__init__()
        self.title("Photo Sorter")
        self.geometry("600x560")
        self.resizable(False, False)
        self.configure(fg_color=BG)

        self._input_var = ctk.StringVar()
        self._output_var = ctk.StringVar()
        self._sorting = False

        self._build_ui()

    # ------------------------------------------------------------ layout
    def _build_ui(self):
        body = ctk.CTkFrame(self, fg_color="transparent")
        body.pack(fill="both", expand=True, padx=28, pady=(22, 20))

        # -- header -------------------------------------------------------
        header = ctk.CTkFrame(body, fg_color="transparent")
        header.pack(fill="x")
        ctk.CTkLabel(
            header, text="Photo Sorter", text_color=TEXT,
            font=ctk.CTkFont(size=24, weight="bold"),
        ).pack(side="left")
        ctk.CTkLabel(
            header, text="RAW / JPG", text_color=ACCENT,
            fg_color=CARD_INNER, corner_radius=6, width=76, height=24,
            font=ctk.CTkFont(size=11, weight="bold"),
        ).pack(side="right", pady=(4, 0))
        ctk.CTkLabel(
            body, text="Separate RAW and JPG files into tidy subfolders.",
            text_color=SUBTLE, font=ctk.CTkFont(size=13),
        ).pack(anchor="w", pady=(1, 14))

        # -- input drop zone ------------------------------------------------
        self._drop = ctk.CTkFrame(
            body, fg_color=CARD, corner_radius=14,
            border_width=2, border_color=BORDER,
        )
        self._drop.pack(fill="x")

        drop_inner = ctk.CTkFrame(self._drop, fg_color="transparent")
        drop_inner.pack(fill="x", padx=18, pady=16)

        self._drop_icon = ctk.CTkLabel(
            drop_inner, text="⌄", width=44, height=30, text_color=ACCENT,
            fg_color=CARD_INNER, corner_radius=10,
            font=ctk.CTkFont(size=20, weight="bold"),
        )
        self._drop_icon.pack(pady=(0, 6))
        self._drop_title = ctk.CTkLabel(
            drop_inner, text="Choose your photo folder", text_color=TEXT,
            font=ctk.CTkFont(size=14, weight="bold"),
        )
        self._drop_title.pack()
        self._drop_sub = ctk.CTkLabel(
            drop_inner, text="Click to browse",
            text_color=SUBTLE, font=ctk.CTkFont(size=12),
        )
        self._drop_sub.pack()

        for w in (self._drop, drop_inner, self._drop_icon, self._drop_title, self._drop_sub):
            w.bind("<Button-1>", lambda _e: self._browse_input())
            w.bind("<Enter>", lambda _e: self._drop_hover(True))
            w.bind("<Leave>", lambda _e: self._drop_hover(False))
            try:
                w.configure(cursor="pointinghand")
            except Exception:
                w.configure(cursor="hand2")

        # -- output folder --------------------------------------------------
        out_wrap = ctk.CTkFrame(body, fg_color="transparent")
        out_wrap.pack(fill="x", pady=(14, 0))
        out_lbl_row = ctk.CTkFrame(out_wrap, fg_color="transparent")
        out_lbl_row.pack(fill="x")
        ctk.CTkLabel(
            out_lbl_row, text="OUTPUT FOLDER", text_color=SUBTLE,
            font=ctk.CTkFont(size=11, weight="bold"),
        ).pack(side="left")
        ctk.CTkLabel(
            out_lbl_row, text="optional — defaults to the input folder",
            text_color=SUBTLE, font=ctk.CTkFont(size=11),
        ).pack(side="right")

        out_row = ctk.CTkFrame(out_wrap, fg_color="transparent")
        out_row.pack(fill="x", pady=(6, 0))
        self._out_entry = ctk.CTkEntry(
            out_row, textvariable=self._output_var, height=38, corner_radius=9,
            placeholder_text="Same as input folder",
            fg_color=CARD, border_color=BORDER, border_width=1, text_color=TEXT,
        )
        self._out_entry.pack(side="left", fill="x", expand=True, padx=(0, 8))
        self._out_btn = ctk.CTkButton(
            out_row, text="Browse", width=86, height=38, corner_radius=9,
            fg_color=CARD_INNER, hover_color=BORDER, text_color=TEXT,
            font=ctk.CTkFont(size=12, weight="bold"),
            command=self._browse_output,
        )
        self._out_btn.pack(side="right")

        # -- action button ---------------------------------------------------
        self._sort_btn = ctk.CTkButton(
            body, text="Sort Photos", height=46, corner_radius=11,
            fg_color=ACCENT, hover_color=ACCENT_HOV,
            font=ctk.CTkFont(size=15, weight="bold"),
            command=self._start_sort,
        )
        self._sort_btn.pack(fill="x", pady=(16, 0))

        # -- progress bar (fixed-height holder so layout never jumps) -------
        prog_holder = ctk.CTkFrame(body, fg_color="transparent", height=14)
        prog_holder.pack(fill="x", pady=(8, 0))
        prog_holder.pack_propagate(False)
        self._progress = ctk.CTkProgressBar(
            prog_holder, mode="indeterminate", height=5, corner_radius=3,
            progress_color=ACCENT, fg_color=CARD_INNER,
        )

        # -- status card -----------------------------------------------------
        self._status_card = ctk.CTkFrame(
            body, fg_color=CARD, corner_radius=14,
            border_width=1, border_color=BORDER_SOFT,
        )
        self._status_card.pack(fill="both", expand=True, pady=(8, 0))
        self._set_status_idle()

    # ------------------------------------------------------------ helpers
    def _drop_hover(self, entered):
        if self._sorting:
            return
        self._drop.configure(border_color=ACCENT if entered else (
            GREEN if self._input_var.get() else BORDER))

    def _clear_status(self):
        for child in self._status_card.winfo_children():
            child.destroy()
        self._status_card.configure(fg_color=CARD, border_color=BORDER_SOFT)

    def _set_status_idle(self):
        self._clear_status()
        wrap = ctk.CTkFrame(self._status_card, fg_color="transparent")
        wrap.place(relx=0.5, rely=0.5, anchor="center")
        ctk.CTkLabel(
            wrap, text="Ready when you are", text_color=TEXT,
            font=ctk.CTkFont(size=13, weight="bold"),
        ).pack()
        ctk.CTkLabel(
            wrap, text="Results will appear here after sorting.",
            text_color=SUBTLE, font=ctk.CTkFont(size=12),
        ).pack(pady=(2, 0))

    def _set_status_message(self, title, detail, color, bg):
        self._clear_status()
        self._status_card.configure(fg_color=bg, border_color=BORDER_SOFT)
        wrap = ctk.CTkFrame(self._status_card, fg_color="transparent")
        wrap.place(relx=0.5, rely=0.5, anchor="center")
        ctk.CTkLabel(
            wrap, text=title, text_color=color,
            font=ctk.CTkFont(size=14, weight="bold"),
        ).pack()
        if detail:
            ctk.CTkLabel(
                wrap, text=detail, text_color=SUBTLE,
                font=ctk.CTkFont(size=12), wraplength=440, justify="center",
            ).pack(pady=(3, 0))

    def _set_status_sorting(self):
        self._set_status_message("Sorting your photos…",
                                 "Hang tight, this usually only takes a moment.",
                                 TEXT, CARD)

    def _set_status_results(self, verb, raws, jpgs, skipped, output_folder):
        self._clear_status()
        self._status_card.configure(fg_color=CARD, border_color=GREEN)

        head = ctk.CTkFrame(self._status_card, fg_color="transparent")
        head.pack(fill="x", padx=18, pady=(14, 8))
        ctk.CTkLabel(
            head, text="✓", width=26, height=26, corner_radius=13,
            fg_color=GREEN_BG, text_color=GREEN,
            font=ctk.CTkFont(size=14, weight="bold"),
        ).pack(side="left")
        ctk.CTkLabel(
            head, text="All done!", text_color=TEXT,
            font=ctk.CTkFont(size=14, weight="bold"),
        ).pack(side="left", padx=(8, 0))
        ctk.CTkLabel(
            head, text=f"{verb} into  {output_folder.name or output_folder}",
            text_color=SUBTLE, font=ctk.CTkFont(size=11),
        ).pack(side="right")

        grid = ctk.CTkFrame(self._status_card, fg_color="transparent")
        grid.pack(fill="x", padx=18, pady=(0, 16))
        for i in range(3):
            grid.grid_columnconfigure(i, weight=1, uniform="stats")

        cells = (
            (str(raws),    f"RAW {verb.lower()}",        ACCENT,                         "→ RAW/"),
            (str(jpgs),    f"JPG {verb.lower()}",        GREEN,                          "→ JPG/"),
            (str(skipped), "duplicates skipped",         AMBER if skipped else SUBTLE,   "left in place"),
        )
        for col, (num, label, color, sub) in enumerate(cells):
            cell = ctk.CTkFrame(grid, fg_color=CARD_INNER, corner_radius=10)
            cell.grid(row=0, column=col, sticky="nsew", padx=(0 if col == 0 else 8, 0))
            ctk.CTkLabel(
                cell, text=num, text_color=color,
                font=ctk.CTkFont(size=24, weight="bold"),
            ).pack(pady=(12, 0))
            ctk.CTkLabel(
                cell, text=label, text_color=TEXT,
                font=ctk.CTkFont(size=11, weight="bold"),
            ).pack()
            ctk.CTkLabel(
                cell, text=sub, text_color=SUBTLE,
                font=ctk.CTkFont(size=10),
            ).pack(pady=(0, 12))

    # ------------------------------------------------------------ actions
    def _browse_input(self):
        if self._sorting:
            return
        path = filedialog.askdirectory(title="Choose your photo folder")
        if path:
            self._input_var.set(path)
            p = Path(path)
            self._drop_icon.configure(text="✓", text_color=GREEN, fg_color=GREEN_BG)
            self._drop_title.configure(text=p.name or str(p))
            self._drop_sub.configure(text=str(p))
            self._drop.configure(border_color=GREEN)

    def _browse_output(self):
        path = filedialog.askdirectory(title="Choose an output folder")
        if path:
            self._output_var.set(path)

    def _start_sort(self):
        input_str = self._input_var.get().strip()
        if not input_str:
            self._set_status_message(
                "No input folder selected",
                "Click the panel above to choose the folder containing your photos.",
                RED, RED_BG,
            )
            return
        input_folder = Path(input_str)
        if not input_folder.is_dir():
            self._set_status_message("Input folder does not exist", str(input_folder), RED, RED_BG)
            return
        output_str = self._output_var.get().strip()
        output_folder = Path(output_str) if output_str else input_folder

        self._sorting = True
        self._sort_btn.configure(state="disabled", text="Sorting…",
                                 fg_color=CARD_INNER, text_color=SUBTLE)
        self._out_btn.configure(state="disabled")
        self._progress.pack(fill="x", pady=(4, 0))
        self._progress.start()
        self._set_status_sorting()

        threading.Thread(target=self._do_sort,
                         args=(input_folder, output_folder), daemon=True).start()

    def _do_sort(self, input_folder, output_folder):
        same   = input_folder.resolve() == output_folder.resolve()
        action = shutil.move if same else shutil.copy2
        verb   = "Moved" if same else "Copied"
        raw_dir = output_folder / "RAW"
        jpg_dir = output_folder / "JPG"
        count_raw = count_jpg = skipped = 0
        try:
            files = [f for f in input_folder.iterdir() if f.is_file()]
            if not any(f.suffix.lower() in RAW_EXTENSIONS | JPG_EXTENSIONS for f in files):
                self.after(0, self._set_status_message,
                           "No RAW or JPG files found",
                           "The selected folder doesn't contain any photos to sort.",
                           AMBER, CARD)
                self.after(0, self._reset_controls)
                return
            for f in files:
                ext = f.suffix.lower()
                if ext in RAW_EXTENSIONS:
                    raw_dir.mkdir(parents=True, exist_ok=True)
                    dest = raw_dir / f.name
                    if dest.exists():
                        skipped += 1
                    else:
                        action(str(f), str(dest))
                        count_raw += 1
                elif ext in JPG_EXTENSIONS:
                    jpg_dir.mkdir(parents=True, exist_ok=True)
                    dest = jpg_dir / f.name
                    if dest.exists():
                        skipped += 1
                    else:
                        action(str(f), str(dest))
                        count_jpg += 1
            self.after(0, self._set_status_results,
                       verb, count_raw, count_jpg, skipped, output_folder)
        except Exception as e:
            self.after(0, self._set_status_message,
                       "Something went wrong", str(e), RED, RED_BG)
        self.after(0, self._reset_controls)

    def _reset_controls(self):
        self._sorting = False
        self._progress.stop()
        self._progress.pack_forget()
        self._sort_btn.configure(state="normal", text="Sort Photos",
                                 fg_color=ACCENT, text_color="#FFFFFF")
        self._out_btn.configure(state="normal")


if __name__ == "__main__":
    app = PhotoSorterApp()
    app.mainloop()
