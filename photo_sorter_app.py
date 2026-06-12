#!/usr/bin/env python3
"""
Photo Sorter & Review
  Tab 1 – Sort  : move/copy RAW+JPG into subfolders with live progress
  Tab 2 – Review: full-screen loupe viewer — keep/skip with keyboard,
           RAW/JPG toggle, filmstrip navigation, auto-advance to undecided,
           session persistence, then export kept RAWs to Lightroom

Requires: customtkinter, Pillow
Optional: rawpy  (embedded RAW preview; falls back to companion JPG)
"""

import io
import json
import threading
import shutil
import collections
from pathlib import Path
from tkinter import filedialog

import customtkinter as ctk
from PIL import Image

try:
    import rawpy
    HAS_RAWPY = True
except ImportError:
    HAS_RAWPY = False

ctk.set_appearance_mode("system")
ctk.set_default_color_theme("blue")

RAW_EXT = {".arw", ".cr2", ".cr3", ".nef", ".raf", ".orf", ".dng", ".rw2", ".pef", ".srw"}
JPG_EXT = {".jpg", ".jpeg"}

# ── Sort tab palette (light / dark tuple) ─────────────────────────
S_BG         = ("#F4F5F7", "#15161A")
S_CARD       = ("#FFFFFF",  "#1E2026")
S_CARD_I     = ("#F2F4F7", "#272A32")
S_BORDER     = ("#E3E6EB", "#32353E")
S_TEXT       = ("#181A20", "#EDEEF2")
S_SUBTLE     = ("#7A8089", "#9AA0AB")
S_ACCENT     = "#4F8EF7"
S_ACCENT_H   = "#3D7DE8"
S_GREEN      = ("#15803D", "#4ADE80")
S_GREEN_BG   = ("#EAF7EF", "#1B2B22")
S_RED        = ("#C92A2A", "#F87171")
S_RED_BG     = ("#FBEDED", "#2C1D1F")
S_AMBER      = ("#B45309", "#FBBF24")

# ── Review tab palette (always dark — neutral for photo judgment) ──
R_APP      = "#242428"
R_STAGE    = "#1A1A1D"
R_CARD     = "#2A2A2E"
R_BORDER   = "#333338"
R_TEXT     = "#E8E8EA"
R_SUBTLE   = "#9A9AA2"
R_HINT     = "#6E6E76"
R_ACCENT   = "#4C8DF5"
R_ACCENT_H = "#3A7DE8"
R_KEEP     = "#3DBE7B"
R_KEEP_BG  = "#1B3A2A"
R_REJECT   = "#E0564F"
R_REJ_BG   = "#3A1E1E"
R_BTN      = "#2E2E33"
R_BTN_H    = "#3A3A40"

FILM_SZ        = 64     # filmstrip thumbnail size (square)
IMG_CACHE_SZ   = 7      # LRU viewer-image cache depth
FLASH_MS       = 120    # flag flash hold before advancing
RESIZE_DEBOUNCE = 160   # ms to wait after resize before reloading


class PhotoSorterApp(ctk.CTk):
    def __init__(self):
        super().__init__()
        self.title("Photo Sorter")
        self.geometry("900x740")
        self.resizable(True, True)
        self.minsize(720, 600)
        self.configure(fg_color=S_BG)

        # ── Sort state ────────────────────────────────────────────
        self._s_folder  = ctk.StringVar()
        self._s_output  = ctk.StringVar()
        self._sorting   = False

        # ── Review state ──────────────────────────────────────────
        self._r_dir      = None        # Path to reviewed folder
        self._r_files    = []          # [Path] RAW files, sorted by name
        self._r_jpg      = {}          # stem -> Path | None
        self._r_stems    = []          # [str]
        self._r_flags    = {}          # stem -> None | "keep" | "skip"
        self._r_idx      = 0
        self._r_mode     = "jpg"       # "jpg" | "raw"
        self._r_cache    = collections.OrderedDict()   # LRU image cache
        self._r_film_cards = {}        # stem -> CTkFrame widget
        self._r_film_imgs  = {}        # stem -> CTkImage (raw thumb for dimming)
        self._r_stage_w  = 1
        self._r_stage_h  = 1
        self._r_resize_job = None

        self._build_ui()

        # ── Keyboard shortcuts ────────────────────────────────────
        for seq, fn in (
            ("<Left>",  lambda e: self._rv_nav(-1)),
            ("<Right>", lambda e: self._rv_nav(+1)),
            ("<Up>",    lambda e: self._rv_keep()),
            ("<Down>",  lambda e: self._rv_skip()),
            ("<k>",     lambda e: self._rv_keep()),
            ("<x>",     lambda e: self._rv_skip()),
            ("<u>",     lambda e: self._rv_unflag()),
            ("<r>",     lambda e: self._rv_toggle_mode()),
            ("<Tab>",   lambda e: self._rv_toggle_mode()),
            ("<Home>",  lambda e: self._rv_goto(0)),
            ("<End>",   lambda e: self._rv_goto(len(self._r_stems) - 1)),
        ):
            self.bind(seq, fn)

    # ════════════════════════════════════════════════════════════════
    #  SHELL
    # ════════════════════════════════════════════════════════════════
    def _build_ui(self):
        self._tabs = ctk.CTkTabview(
            self, fg_color=S_BG,
            segmented_button_fg_color=S_CARD_I,
            segmented_button_selected_color=S_ACCENT,
            segmented_button_unselected_color=S_CARD_I,
            segmented_button_selected_hover_color=S_ACCENT_H,
        )
        self._tabs.pack(fill="both", expand=True)
        self._build_sort_tab(self._tabs.add("  Sort  "))
        self._build_review_tab(self._tabs.add("  Review  "))

    # ════════════════════════════════════════════════════════════════
    #  SORT TAB
    # ════════════════════════════════════════════════════════════════
    def _build_sort_tab(self, parent):
        body = ctk.CTkFrame(parent, fg_color="transparent")
        body.pack(fill="both", expand=True, padx=28, pady=(18, 20))

        # Header
        hdr = ctk.CTkFrame(body, fg_color="transparent")
        hdr.pack(fill="x")
        ctk.CTkLabel(hdr, text="Sort Photos", text_color=S_TEXT,
                     font=ctk.CTkFont(size=22, weight="bold")).pack(side="left")
        ctk.CTkLabel(hdr, text="RAW / JPG", text_color=S_ACCENT,
                     fg_color=S_CARD_I, corner_radius=6, width=76, height=24,
                     font=ctk.CTkFont(size=11, weight="bold")).pack(side="right", pady=(4, 0))
        ctk.CTkLabel(body, text="Separate RAW and JPG files into tidy subfolders.",
                     text_color=S_SUBTLE, font=ctk.CTkFont(size=13)).pack(anchor="w", pady=(2, 14))

        # Drop zone
        self._s_drop = ctk.CTkFrame(body, fg_color=S_CARD, corner_radius=14,
                                     border_width=2, border_color=S_BORDER)
        self._s_drop.pack(fill="x")
        di = ctk.CTkFrame(self._s_drop, fg_color="transparent")
        di.pack(fill="x", padx=18, pady=14)
        self._s_drop_icon = ctk.CTkLabel(di, text="⌄", width=44, height=30, text_color=S_ACCENT,
                                          fg_color=S_CARD_I, corner_radius=10,
                                          font=ctk.CTkFont(size=20, weight="bold"))
        self._s_drop_icon.pack(pady=(0, 5))
        self._s_drop_title = ctk.CTkLabel(di, text="Choose your photo folder",
                                           text_color=S_TEXT, font=ctk.CTkFont(size=14, weight="bold"))
        self._s_drop_title.pack()
        self._s_drop_sub = ctk.CTkLabel(di, text="Click to browse",
                                         text_color=S_SUBTLE, font=ctk.CTkFont(size=12))
        self._s_drop_sub.pack()
        for w in (self._s_drop, di, self._s_drop_icon, self._s_drop_title, self._s_drop_sub):
            w.bind("<Button-1>", lambda _e: self._s_browse_input())
            w.bind("<Enter>",   lambda _e: self._s_drop_hover(True))
            w.bind("<Leave>",   lambda _e: self._s_drop_hover(False))
            try:    w.configure(cursor="pointinghand")
            except: w.configure(cursor="hand2")

        # Output folder
        ow = ctk.CTkFrame(body, fg_color="transparent")
        ow.pack(fill="x", pady=(14, 0))
        olr = ctk.CTkFrame(ow, fg_color="transparent")
        olr.pack(fill="x")
        ctk.CTkLabel(olr, text="OUTPUT FOLDER", text_color=S_SUBTLE,
                     font=ctk.CTkFont(size=11, weight="bold")).pack(side="left")
        ctk.CTkLabel(olr, text="optional — defaults to input folder",
                     text_color=S_SUBTLE, font=ctk.CTkFont(size=11)).pack(side="right")
        or_ = ctk.CTkFrame(ow, fg_color="transparent")
        or_.pack(fill="x", pady=(6, 0))
        ctk.CTkEntry(or_, textvariable=self._s_output, height=38, corner_radius=9,
                     placeholder_text="Same as input folder",
                     fg_color=S_CARD, border_color=S_BORDER, border_width=1,
                     text_color=S_TEXT).pack(side="left", fill="x", expand=True, padx=(0, 8))
        self._s_out_btn = ctk.CTkButton(or_, text="Browse", width=86, height=38, corner_radius=9,
                                         fg_color=S_CARD_I, hover_color=S_BORDER, text_color=S_TEXT,
                                         font=ctk.CTkFont(size=12, weight="bold"),
                                         command=self._s_browse_output)
        self._s_out_btn.pack(side="right")

        # Sort button
        self._s_sort_btn = ctk.CTkButton(body, text="Sort Photos", height=46, corner_radius=11,
                                          fg_color=S_ACCENT, hover_color=S_ACCENT_H,
                                          font=ctk.CTkFont(size=15, weight="bold"),
                                          command=self._s_start_sort)
        self._s_sort_btn.pack(fill="x", pady=(16, 0))

        # Progress
        prog_area = ctk.CTkFrame(body, fg_color="transparent")
        prog_area.pack(fill="x", pady=(10, 0))
        self._s_prog_lbl = ctk.CTkLabel(prog_area, text="", text_color=S_SUBTLE,
                                         font=ctk.CTkFont(family="Courier", size=11))
        self._s_prog_lbl.pack(anchor="w")
        self._s_prog_bar = ctk.CTkProgressBar(prog_area, height=6, corner_radius=3,
                                               progress_color=S_ACCENT, fg_color=S_CARD_I)
        self._s_prog_bar.set(0)

        # Status card
        self._s_status = ctk.CTkFrame(body, fg_color=S_CARD, corner_radius=14,
                                       border_width=1, border_color=S_BORDER)
        self._s_status.pack(fill="both", expand=True, pady=(10, 0))
        self._s_set_idle()

    # ════════════════════════════════════════════════════════════════
    #  REVIEW TAB
    # ════════════════════════════════════════════════════════════════
    def _build_review_tab(self, parent):
        parent.configure(fg_color=R_APP)

        # 1. Info bar (top)
        self._rv_build_info_bar(parent)

        # 2. Viewer row (fills remaining height)
        row = ctk.CTkFrame(parent, fg_color=R_APP)
        row.pack(fill="both", expand=True)
        row.grid_rowconfigure(0, weight=1)
        row.grid_columnconfigure(1, weight=1)

        # Left nav arrow
        self._rv_left = ctk.CTkButton(
            row, text="‹", width=44, font=ctk.CTkFont(size=30),
            fg_color="transparent", hover_color=R_BTN_H,
            text_color=R_SUBTLE, corner_radius=8,
            command=lambda: self._rv_nav(-1),
        )
        self._rv_left.grid(row=0, column=0, sticky="ns", padx=(10, 0), pady=10)

        # Stage (dark image surround)
        self._rv_stage = ctk.CTkFrame(row, fg_color=R_STAGE, corner_radius=12)
        self._rv_stage.grid(row=0, column=1, sticky="nsew", padx=8, pady=10)
        self._rv_stage.bind("<Configure>", self._rv_on_stage_resize)

        # Image label (centered via place)
        self._rv_img = ctk.CTkLabel(self._rv_stage, text="", fg_color="transparent")
        self._rv_img.place(relx=0.5, rely=0.5, anchor="center")

        # Empty state
        self._rv_empty = ctk.CTkLabel(
            self._rv_stage, text="Open a folder to start reviewing",
            text_color=R_SUBTLE, font=ctk.CTkFont(size=14), fg_color="transparent",
        )
        self._rv_empty.place(relx=0.5, rely=0.5, anchor="center")

        # Flag edge bar — 6px strip along left edge of stage
        self._rv_flag_bar = ctk.CTkFrame(
            self._rv_stage, width=6, fg_color="transparent", corner_radius=0,
        )
        self._rv_flag_bar.place(x=0, y=0, relheight=1)

        # Flag badge — top-left corner
        self._rv_flag_badge = ctk.CTkLabel(
            self._rv_stage, text="", height=22, corner_radius=4, width=0,
            font=ctk.CTkFont(size=11, weight="bold"), fg_color="transparent",
            text_color=R_TEXT,
        )
        self._rv_flag_badge.place(x=14, y=10)

        # Right nav arrow
        self._rv_right = ctk.CTkButton(
            row, text="›", width=44, font=ctk.CTkFont(size=30),
            fg_color="transparent", hover_color=R_BTN_H,
            text_color=R_SUBTLE, corner_radius=8,
            command=lambda: self._rv_nav(+1),
        )
        self._rv_right.grid(row=0, column=2, sticky="ns", padx=(0, 10), pady=10)

        # 3. Filmstrip
        self._rv_build_filmstrip(parent)

        # 4. Status / action bar (bottom)
        self._rv_build_status_bar(parent)

    def _rv_build_info_bar(self, parent):
        bar = ctk.CTkFrame(parent, fg_color=R_APP, height=40)
        bar.pack(fill="x")
        bar.pack_propagate(False)
        ctk.CTkFrame(bar, height=1, fg_color=R_BORDER).pack(fill="x", side="bottom")

        bi = ctk.CTkFrame(bar, fg_color="transparent")
        bi.pack(fill="both", expand=True, padx=14)

        # Left: filename
        self._rv_fname = ctk.CTkLabel(bi, text="—", text_color=R_TEXT,
                                       font=ctk.CTkFont(size=13, weight="bold"))
        self._rv_fname.pack(side="left")

        # Left+: pair pill
        self._rv_pair = ctk.CTkLabel(bi, text="", height=20, corner_radius=4,
                                      fg_color=R_CARD, text_color=R_SUBTLE,
                                      font=ctk.CTkFont(size=11), width=80)
        self._rv_pair.pack(side="left", padx=(10, 0))

        # Right: Open Folder
        ctk.CTkButton(
            bi, text="Open Folder", width=100, height=28, corner_radius=7,
            fg_color=R_ACCENT, hover_color=R_ACCENT_H, text_color="#fff",
            font=ctk.CTkFont(size=12, weight="bold"),
            command=self._rv_load_folder,
        ).pack(side="right")

        # Right: RAW/JPG toggle
        self._rv_mode_toggle = ctk.CTkSegmentedButton(
            bi, values=["JPG", "RAW"], width=120, height=28,
            font=ctk.CTkFont(size=12, weight="bold"),
            fg_color=R_BTN,
            selected_color=R_ACCENT, selected_hover_color=R_ACCENT_H,
            unselected_color=R_BTN, unselected_hover_color=R_BTN_H,
            text_color_disabled=R_HINT,
            command=self._rv_on_mode_toggle,
        )
        self._rv_mode_toggle.set("JPG")
        self._rv_mode_toggle.pack(side="right", padx=(0, 10))

        # Right: counter
        self._rv_counter = ctk.CTkLabel(bi, text="—", text_color=R_SUBTLE,
                                         font=ctk.CTkFont(size=13), width=80)
        self._rv_counter.pack(side="right", padx=(0, 12))

    def _rv_build_filmstrip(self, parent):
        outer = ctk.CTkFrame(parent, fg_color=R_APP, height=88)
        outer.pack(fill="x")
        outer.pack_propagate(False)
        ctk.CTkFrame(outer, height=1, fg_color=R_BORDER).pack(fill="x", side="top")

        try:
            self._rv_film = ctk.CTkScrollableFrame(
                outer, height=84, orientation="horizontal",
                fg_color=R_APP, corner_radius=0,
            )
        except TypeError:
            self._rv_film = ctk.CTkScrollableFrame(
                outer, height=84, fg_color=R_APP, corner_radius=0,
            )
        self._rv_film.pack(fill="x", padx=6)

    def _rv_build_status_bar(self, parent):
        bar = ctk.CTkFrame(parent, fg_color=R_APP, height=40)
        bar.pack(fill="x", side="bottom")
        bar.pack_propagate(False)
        ctk.CTkFrame(bar, height=1, fg_color=R_BORDER).pack(fill="x", side="top")

        bi = ctk.CTkFrame(bar, fg_color="transparent")
        bi.pack(fill="both", expand=True, padx=14)

        # Left: tally
        self._rv_tally = ctk.CTkLabel(bi, text="", text_color=R_SUBTLE,
                                       font=ctk.CTkFont(size=12))
        self._rv_tally.pack(side="left")

        # Right: copy button
        self._rv_copy_btn = ctk.CTkButton(
            bi, text="Copy Kept RAWs  →", width=140, height=26, corner_radius=6,
            fg_color=R_ACCENT, hover_color=R_ACCENT_H, text_color="#fff",
            font=ctk.CTkFont(size=12, weight="bold"),
            command=self._rv_copy_kept,
            state="disabled",
        )
        self._rv_copy_btn.pack(side="right")

        # Right: also copy JPGs
        self._rv_also_jpg = ctk.BooleanVar(value=True)
        ctk.CTkCheckBox(
            bi, text="Also copy JPGs", variable=self._rv_also_jpg,
            text_color=R_SUBTLE, font=ctk.CTkFont(size=12),
            fg_color=R_ACCENT, hover_color=R_ACCENT_H, border_color=R_BTN_H,
        ).pack(side="right", padx=(0, 12))

        # Right-center: keyboard hint
        ctk.CTkLabel(
            bi,
            text="← → navigate   ↑ keep   ↓ skip   U unflag   R raw/jpg",
            text_color=R_HINT, font=ctk.CTkFont(size=11),
        ).pack(side="right", padx=(0, 20))

    # ════════════════════════════════════════════════════════════════
    #  REVIEW — FOLDER LOADING
    # ════════════════════════════════════════════════════════════════
    def _rv_load_folder(self):
        path = filedialog.askdirectory(title="Choose a folder to review")
        if not path:
            return
        self._r_dir = Path(path)

        # Reset
        self._r_files.clear(); self._r_jpg.clear()
        self._r_stems.clear(); self._r_flags.clear()
        self._r_idx = 0; self._r_mode = "jpg"
        self._r_cache.clear(); self._r_film_cards.clear()
        self._r_film_imgs.clear()
        self._rv_mode_toggle.set("JPG")

        for w in self._rv_film.winfo_children():
            w.destroy()

        self._rv_img.configure(image=None, text="")
        self._rv_empty.configure(text="Scanning…")
        self._rv_empty.lift()
        self._rv_fname.configure(text="Scanning…")
        self._rv_tally.configure(text="")

        # Load any saved session
        self._rv_load_session()

        threading.Thread(target=self._rv_scan, args=(self._r_dir,), daemon=True).start()

    def _rv_scan(self, folder: Path):
        # Collect RAW files
        raws = sorted(
            [f for f in folder.iterdir() if f.is_file() and f.suffix.lower() in RAW_EXT],
            key=lambda f: f.name,
        )
        raw_sub = folder / "RAW"
        if raw_sub.is_dir():
            raws += sorted(
                [f for f in raw_sub.iterdir() if f.is_file() and f.suffix.lower() in RAW_EXT],
                key=lambda f: f.name,
            )

        if not raws:
            self.after(0, lambda: self._rv_empty.configure(
                text="No RAW files found in this folder"))
            self.after(0, lambda: self._rv_fname.configure(text="—"))
            return

        jpg_sub = folder / "JPG"
        for f in raws:
            stem = f.stem
            found = None
            for ext in (".jpg", ".JPG", ".jpeg", ".JPEG"):
                for d in (folder, jpg_sub):
                    c = d / (stem + ext)
                    if c.is_file():
                        found = c; break
                if found: break
            self._r_jpg[stem] = found

        self._r_files = raws
        self._r_stems = [f.stem for f in raws]
        for s in self._r_stems:
            if s not in self._r_flags:
                self._r_flags[s] = None

        # Build filmstrip placeholders (all at once in main thread)
        self.after(0, self._rv_build_filmstrip_cards)

        # Load filmstrip thumbnails in background
        for raw_f in raws:
            stem = raw_f.stem
            jpg  = self._r_jpg.get(stem)
            thumb = self._rv_make_film_thumb(jpg or raw_f)
            self._r_film_imgs[stem] = thumb
            self.after(0, self._rv_update_film_thumb, stem)

        # Show first photo
        self.after(0, lambda: self._rv_goto(0))
        total = len(raws)
        self.after(0, lambda: self._rv_fname.configure(
            text=f"{folder.name}  —  {total} RAW files"))

    def _rv_build_filmstrip_cards(self):
        for i, stem in enumerate(self._r_stems):
            flag = self._r_flags.get(stem)
            bc   = self._rv_flag_border(flag, current=(i == self._r_idx))

            card = ctk.CTkFrame(
                self._rv_film, width=FILM_SZ + 4, height=FILM_SZ + 18,
                fg_color=R_CARD, corner_radius=6,
                border_width=2, border_color=bc,
            )
            card.pack(side="left", padx=4, pady=6)
            card.pack_propagate(False)

            img_lbl = ctk.CTkLabel(card, text="", fg_color="transparent")
            img_lbl.place(x=0, y=0, relwidth=1, height=FILM_SZ)

            name_lbl = ctk.CTkLabel(
                card, text=stem[-8:], fg_color="transparent",
                text_color=R_SUBTLE, font=ctk.CTkFont(size=9),
            )
            name_lbl.place(x=0, relwidth=1, y=FILM_SZ, height=16)

            card._img_lbl  = img_lbl
            card._name_lbl = name_lbl
            card._stem     = stem
            self._r_film_cards[stem] = card

            idx = i
            def on_click(_e, i=idx): self._rv_goto(i)
            card.bind("<Button-1>", on_click)
            img_lbl.bind("<Button-1>", on_click)
            name_lbl.bind("<Button-1>", on_click)
            try:    card.configure(cursor="pointinghand")
            except: card.configure(cursor="hand2")

    def _rv_make_film_thumb(self, path: Path) -> ctk.CTkImage:
        try:
            if path.suffix.lower() in RAW_EXT and HAS_RAWPY:
                with rawpy.imread(str(path)) as raw:
                    t = raw.extract_thumb()
                    img = Image.open(io.BytesIO(t.data)) if t.format == rawpy.ThumbFormat.JPEG \
                          else Image.fromarray(t.data)
            else:
                img = Image.open(path)
            w, h = img.size
            dim  = min(w, h)
            img  = img.crop(((w-dim)//2, (h-dim)//2, (w+dim)//2, (h+dim)//2))
            img  = img.resize((FILM_SZ, FILM_SZ), Image.LANCZOS)
            return ctk.CTkImage(light_image=img, dark_image=img, size=(FILM_SZ, FILM_SZ))
        except Exception:
            ph = Image.new("RGB", (FILM_SZ, FILM_SZ), (46, 46, 52))
            return ctk.CTkImage(light_image=ph, dark_image=ph, size=(FILM_SZ, FILM_SZ))

    def _rv_update_film_thumb(self, stem: str):
        card  = self._r_film_cards.get(stem)
        thumb = self._r_film_imgs.get(stem)
        if card and thumb and hasattr(card, "_img_lbl"):
            flag = self._r_flags.get(stem)
            if flag == "skip":
                disp = self._rv_dim(thumb)
            else:
                disp = thumb
            card._img_lbl.configure(image=disp, text="")

    def _rv_dim(self, ctkimg: ctk.CTkImage) -> ctk.CTkImage:
        try:
            src  = ctkimg._light_image.copy().convert("RGB")
            dark = Image.new("RGB", src.size, (28, 28, 32))
            blended = Image.blend(src, dark, alpha=0.55)
            return ctk.CTkImage(light_image=blended, dark_image=blended,
                               size=(FILM_SZ, FILM_SZ))
        except Exception:
            return ctkimg

    # ════════════════════════════════════════════════════════════════
    #  REVIEW — NAVIGATION
    # ════════════════════════════════════════════════════════════════
    def _rv_nav(self, delta: int):
        if self._tabs.get() != "  Review  " or not self._r_stems:
            return
        self._rv_goto(max(0, min(len(self._r_stems) - 1, self._r_idx + delta)))

    def _rv_goto(self, idx: int):
        if not self._r_stems or not (0 <= idx < len(self._r_stems)):
            return

        old = self._r_idx
        self._r_idx = idx
        self._r_mode = "jpg"
        self._rv_mode_toggle.set("JPG")

        # Filmstrip: de-highlight old, highlight new
        if old != idx and old < len(self._r_stems):
            self._rv_refresh_film(self._r_stems[old])
        self._rv_refresh_film(self._r_stems[idx])
        self._rv_scroll_film(idx)

        # Nav arrow states
        self._rv_left.configure(
            state="normal" if idx > 0 else "disabled",
            text_color=R_SUBTLE if idx > 0 else R_HINT,
        )
        self._rv_right.configure(
            state="normal" if idx < len(self._r_stems) - 1 else "disabled",
            text_color=R_SUBTLE if idx < len(self._r_stems) - 1 else R_HINT,
        )

        self._rv_update_info(idx)
        self._rv_update_flag_ui(self._r_stems[idx])
        self._rv_update_tally()
        self._rv_load_image(idx, "jpg")

        # Preload adjacent
        threading.Thread(target=self._rv_preload, args=(idx,), daemon=True).start()

    def _rv_scroll_film(self, idx: int):
        def do():
            try:
                total = len(self._r_stems)
                if total < 2:
                    return
                frac = (idx / (total - 1)) - 0.08
                canvas = getattr(self._rv_film, "_parent_canvas", None)
                if canvas:
                    canvas.xview_moveto(max(0.0, frac))
            except Exception:
                pass
        self.after(60, do)

    # ════════════════════════════════════════════════════════════════
    #  REVIEW — FLAG ACTIONS
    # ════════════════════════════════════════════════════════════════
    def _rv_keep(self):
        if self._tabs.get() != "  Review  " or not self._r_stems:
            return
        stem = self._r_stems[self._r_idx]
        self._r_flags[stem] = "keep"
        self._rv_update_flag_ui(stem)
        self._rv_refresh_film(stem)
        self._rv_update_tally()
        self._rv_save_session()
        self.after(FLASH_MS, self._rv_advance_undecided)

    def _rv_skip(self):
        if self._tabs.get() != "  Review  " or not self._r_stems:
            return
        stem = self._r_stems[self._r_idx]
        self._r_flags[stem] = "skip"
        self._rv_update_flag_ui(stem)
        self._rv_refresh_film(stem)
        self._rv_update_film_thumb(stem)   # re-dim
        self._rv_update_tally()
        self._rv_save_session()
        self.after(FLASH_MS, self._rv_advance_undecided)

    def _rv_unflag(self):
        if self._tabs.get() != "  Review  " or not self._r_stems:
            return
        stem = self._r_stems[self._r_idx]
        self._r_flags[stem] = None
        self._rv_update_flag_ui(stem)
        self._rv_refresh_film(stem)
        self._rv_update_film_thumb(stem)   # un-dim
        self._rv_update_tally()
        self._rv_save_session()

    def _rv_advance_undecided(self):
        """Jump to the next undecided photo; if none, advance by 1."""
        for i in range(self._r_idx + 1, len(self._r_stems)):
            if self._r_flags.get(self._r_stems[i]) is None:
                self._rv_goto(i)
                return
        if self._r_idx < len(self._r_stems) - 1:
            self._rv_goto(self._r_idx + 1)

    # ════════════════════════════════════════════════════════════════
    #  REVIEW — IMAGE LOADING
    # ════════════════════════════════════════════════════════════════
    def _rv_load_image(self, idx: int, mode: str):
        if not self._r_stems or idx >= len(self._r_files):
            return
        raw_f = self._r_files[idx]
        stem  = self._r_stems[idx]
        jpg_f = self._r_jpg.get(stem)

        src = raw_f if (mode == "raw" and HAS_RAWPY) else (jpg_f or raw_f)
        w   = max(self._r_stage_w - 24, 100)
        h   = max(self._r_stage_h - 24, 100)
        key = (str(src), mode, w, h)

        if key in self._r_cache:
            self._r_cache.move_to_end(key)
            self._rv_display(self._r_cache[key])
            self._rv_empty.lower()
            return

        threading.Thread(
            target=self._rv_decode,
            args=(idx, src, mode, w, h, key),
            daemon=True,
        ).start()

    def _rv_decode(self, idx: int, src: Path, mode: str, w: int, h: int, key: tuple):
        try:
            if mode == "raw" and HAS_RAWPY and src.suffix.lower() in RAW_EXT:
                with rawpy.imread(str(src)) as raw:
                    t   = raw.extract_thumb()
                    img = Image.open(io.BytesIO(t.data)) \
                          if t.format == rawpy.ThumbFormat.JPEG \
                          else Image.fromarray(t.data)
            else:
                img = Image.open(src)

            img    = self._rv_fit(img, w, h)
            ctkimg = ctk.CTkImage(light_image=img, dark_image=img,
                                  size=(img.width, img.height))

            self._r_cache[key] = ctkimg
            while len(self._r_cache) > IMG_CACHE_SZ:
                self._r_cache.popitem(last=False)

            if self._r_idx == idx:
                self.after(0, self._rv_display, ctkimg)
                self.after(0, self._rv_empty.lower)

        except Exception as exc:
            if self._r_idx == idx:
                self.after(0, lambda: self._rv_img.configure(
                    image=None, text=f"Cannot load image\n{exc}",
                    text_color=R_SUBTLE))

    def _rv_fit(self, img: Image.Image, max_w: int, max_h: int) -> Image.Image:
        iw, ih = img.size
        scale  = min(max_w / iw, max_h / ih, 1.0)
        if scale < 0.999:
            img = img.resize((int(iw * scale), int(ih * scale)), Image.LANCZOS)
        return img

    def _rv_display(self, ctkimg: ctk.CTkImage):
        self._rv_img.configure(image=ctkimg, text="")
        self._rv_img.image = ctkimg  # prevent GC

    def _rv_preload(self, idx: int):
        for offset in (+1, -1, +2):
            adj = idx + offset
            if not (0 <= adj < len(self._r_files)):
                continue
            stem  = self._r_stems[adj]
            jpg   = self._r_jpg.get(stem)
            src   = jpg or self._r_files[adj]
            w     = max(self._r_stage_w - 24, 100)
            h     = max(self._r_stage_h - 24, 100)
            key   = (str(src), "jpg", w, h)
            if key not in self._r_cache:
                try:
                    img    = Image.open(src)
                    img    = self._rv_fit(img, w, h)
                    ctkimg = ctk.CTkImage(light_image=img, dark_image=img,
                                         size=(img.width, img.height))
                    self._r_cache[key] = ctkimg
                    while len(self._r_cache) > IMG_CACHE_SZ:
                        self._r_cache.popitem(last=False)
                except Exception:
                    pass

    def _rv_on_stage_resize(self, event):
        if self._r_resize_job:
            self.after_cancel(self._r_resize_job)
        self._r_resize_job = self.after(
            RESIZE_DEBOUNCE, self._rv_handle_resize, event.width, event.height)

    def _rv_handle_resize(self, w: int, h: int):
        if w != self._r_stage_w or h != self._r_stage_h:
            self._r_stage_w, self._r_stage_h = w, h
            self._r_cache.clear()
            if self._r_stems:
                self._rv_load_image(self._r_idx, self._r_mode)

    # ════════════════════════════════════════════════════════════════
    #  REVIEW — UI HELPERS
    # ════════════════════════════════════════════════════════════════
    def _rv_flag_border(self, flag, current=False):
        if current:     return R_ACCENT
        if flag == "keep":  return R_KEEP
        if flag == "skip":  return R_REJECT
        return R_BTN_H

    def _rv_refresh_film(self, stem: str):
        card = self._r_film_cards.get(stem)
        if not card:
            return
        idx  = self._r_stems.index(stem) if stem in self._r_stems else -1
        flag = self._r_flags.get(stem)
        card.configure(border_color=self._rv_flag_border(flag, current=(idx == self._r_idx)))

    def _rv_update_info(self, idx: int):
        stem  = self._r_stems[idx]
        raw_f = self._r_files[idx]
        jpg_f = self._r_jpg.get(stem)
        self._rv_fname.configure(text=f"{stem}{raw_f.suffix.upper()}")
        self._rv_pair.configure(
            text="RAW + JPG" if jpg_f else "RAW only",
            fg_color=R_CARD if jpg_f else "#3A2A18",
        )
        self._rv_mode_toggle.configure(state="normal" if HAS_RAWPY else "disabled")
        self._rv_counter.configure(text=f"{idx + 1} / {len(self._r_stems)}")

    def _rv_update_flag_ui(self, stem: str):
        flag = self._r_flags.get(stem)
        if flag == "keep":
            self._rv_flag_bar.configure(fg_color=R_KEEP)
            self._rv_flag_badge.configure(
                text="  ✓  KEEP  ", fg_color=R_KEEP_BG, text_color=R_KEEP)
        elif flag == "skip":
            self._rv_flag_bar.configure(fg_color=R_REJECT)
            self._rv_flag_badge.configure(
                text="  ✗  SKIP  ", fg_color=R_REJ_BG, text_color=R_REJECT)
        else:
            self._rv_flag_bar.configure(fg_color="transparent")
            self._rv_flag_badge.configure(text="", fg_color="transparent")

    def _rv_update_tally(self):
        kept  = sum(1 for v in self._r_flags.values() if v == "keep")
        skip  = sum(1 for v in self._r_flags.values() if v == "skip")
        undec = sum(1 for v in self._r_flags.values() if v is None)
        self._rv_tally.configure(
            text=f"✓ {kept} kept   ✗ {skip} skipped   · {undec} undecided")
        self._rv_copy_btn.configure(state="normal" if kept > 0 else "disabled")

    def _rv_toggle_mode(self):
        if self._tabs.get() != "  Review  " or not self._r_stems:
            return
        self._r_mode = "raw" if self._r_mode == "jpg" else "jpg"
        self._rv_mode_toggle.set("RAW" if self._r_mode == "raw" else "JPG")
        self._rv_load_image(self._r_idx, self._r_mode)

    def _rv_on_mode_toggle(self, value: str):
        self._r_mode = "raw" if value == "RAW" else "jpg"
        if self._r_stems:
            self._rv_load_image(self._r_idx, self._r_mode)

    # ════════════════════════════════════════════════════════════════
    #  REVIEW — SESSION + COPY
    # ════════════════════════════════════════════════════════════════
    def _rv_save_session(self):
        if not self._r_dir:
            return
        try:
            data = {s: v for s, v in self._r_flags.items() if v is not None}
            (self._r_dir / "cull_session.json").write_text(json.dumps(data, indent=2))
        except Exception:
            pass

    def _rv_load_session(self):
        if not self._r_dir:
            return
        try:
            p = self._r_dir / "cull_session.json"
            if p.exists():
                self._r_flags.update(json.loads(p.read_text()))
        except Exception:
            pass

    def _rv_copy_kept(self):
        kept = [s for s, v in self._r_flags.items() if v == "keep"]
        if not kept or not self._r_dir:
            return
        out = filedialog.askdirectory(title="Choose output folder for kept RAWs")
        if not out:
            return
        out_path = Path(out)
        out_path.mkdir(parents=True, exist_ok=True)
        folder   = self._r_dir
        raw_sub  = folder / "RAW"
        jpg_sub  = folder / "JPG"
        also_jpg = self._rv_also_jpg.get()

        def do():
            count = 0
            for stem in kept:
                for ext in RAW_EXT:
                    for d in (folder, raw_sub):
                        if not d.is_dir(): continue
                        f = d / (stem + ext)
                        if f.exists():
                            shutil.copy2(str(f), str(out_path / f.name))
                            count += 1; break
                if also_jpg:
                    for ext in JPG_EXT:
                        for d in (folder, jpg_sub):
                            if not d.is_dir(): continue
                            f = d / (stem + ext)
                            if f.exists():
                                shutil.copy2(str(f), str(out_path / f.name)); break
            self.after(0, lambda: self._rv_tally.configure(
                text=f"✓  Copied {count} files  →  {out_path.name}"))

        threading.Thread(target=do, daemon=True).start()

    # ════════════════════════════════════════════════════════════════
    #  SORT — HELPERS
    # ════════════════════════════════════════════════════════════════
    def _s_drop_hover(self, entered: bool):
        if self._sorting:
            return
        self._s_drop.configure(
            border_color=S_ACCENT if entered else
            (S_GREEN if self._s_folder.get() else S_BORDER))

    def _s_browse_input(self):
        if self._sorting:
            return
        path = filedialog.askdirectory(title="Choose your photo folder")
        if path:
            self._s_folder.set(path)
            p = Path(path)
            self._s_drop_icon.configure(text="✓", text_color=S_GREEN, fg_color=S_GREEN_BG)
            self._s_drop_title.configure(text=p.name or str(p))
            self._s_drop_sub.configure(text=str(p))
            self._s_drop.configure(border_color=S_GREEN)

    def _s_browse_output(self):
        path = filedialog.askdirectory()
        if path:
            self._s_output.set(path)

    def _s_clear_status(self):
        for c in self._s_status.winfo_children():
            c.destroy()
        self._s_status.configure(fg_color=S_CARD, border_color=S_BORDER)

    def _s_set_idle(self):
        self._s_clear_status()
        w = ctk.CTkFrame(self._s_status, fg_color="transparent")
        w.place(relx=0.5, rely=0.5, anchor="center")
        ctk.CTkLabel(w, text="Ready when you are", text_color=S_TEXT,
                     font=ctk.CTkFont(size=13, weight="bold")).pack()
        ctk.CTkLabel(w, text="Results will appear here after sorting.",
                     text_color=S_SUBTLE, font=ctk.CTkFont(size=12)).pack(pady=(2, 0))

    def _s_set_msg(self, title, detail, color, bg):
        self._s_clear_status()
        self._s_status.configure(fg_color=bg, border_color=S_BORDER)
        w = ctk.CTkFrame(self._s_status, fg_color="transparent")
        w.place(relx=0.5, rely=0.5, anchor="center")
        ctk.CTkLabel(w, text=title, text_color=color,
                     font=ctk.CTkFont(size=14, weight="bold")).pack()
        if detail:
            ctk.CTkLabel(w, text=detail, text_color=S_SUBTLE, font=ctk.CTkFont(size=12),
                         wraplength=500, justify="center").pack(pady=(3, 0))

    def _s_set_results(self, verb, raws, jpgs, skipped, out):
        self._s_clear_status()
        self._s_status.configure(fg_color=S_CARD, border_color=S_GREEN)
        head = ctk.CTkFrame(self._s_status, fg_color="transparent")
        head.pack(fill="x", padx=18, pady=(14, 8))
        ctk.CTkLabel(head, text="✓", width=26, height=26, corner_radius=13,
                     fg_color=S_GREEN_BG, text_color=S_GREEN,
                     font=ctk.CTkFont(size=14, weight="bold")).pack(side="left")
        ctk.CTkLabel(head, text="All done!", text_color=S_TEXT,
                     font=ctk.CTkFont(size=14, weight="bold")).pack(side="left", padx=(8, 0))
        ctk.CTkLabel(head, text=f"{verb} into  {out.name or out}",
                     text_color=S_SUBTLE, font=ctk.CTkFont(size=11)).pack(side="right")
        g = ctk.CTkFrame(self._s_status, fg_color="transparent")
        g.pack(fill="x", padx=18, pady=(0, 16))
        for i in range(3):
            g.grid_columnconfigure(i, weight=1, uniform="s")
        for col, (num, lbl, color, sub) in enumerate((
            (str(raws),    f"RAW {verb.lower()}",    S_ACCENT,                      "→ RAW/"),
            (str(jpgs),    f"JPG {verb.lower()}",    S_GREEN,                       "→ JPG/"),
            (str(skipped), "duplicates skipped",     S_AMBER if skipped else S_SUBTLE, "left in place"),
        )):
            c = ctk.CTkFrame(g, fg_color=S_CARD_I, corner_radius=10)
            c.grid(row=0, column=col, sticky="nsew", padx=(0 if col == 0 else 8, 0))
            ctk.CTkLabel(c, text=num,  text_color=color, font=ctk.CTkFont(size=24, weight="bold")).pack(pady=(12, 0))
            ctk.CTkLabel(c, text=lbl,  text_color=S_TEXT, font=ctk.CTkFont(size=11, weight="bold")).pack()
            ctk.CTkLabel(c, text=sub,  text_color=S_SUBTLE, font=ctk.CTkFont(size=10)).pack(pady=(0, 12))

    def _s_start_sort(self):
        inp = self._s_folder.get().strip()
        if not inp:
            self._s_set_msg("No input folder selected",
                            "Click the panel above to choose the folder containing your photos.",
                            S_RED, S_RED_BG)
            return
        in_f = Path(inp)
        if not in_f.is_dir():
            self._s_set_msg("Input folder does not exist", inp, S_RED, S_RED_BG)
            return
        out_s = self._s_output.get().strip()
        out_f = Path(out_s) if out_s else in_f

        self._sorting = True
        self._s_sort_btn.configure(state="disabled", text="Sorting…",
                                    fg_color=S_CARD_I, text_color=S_SUBTLE)
        self._s_out_btn.configure(state="disabled")
        self._s_prog_bar.set(0)
        self._s_prog_bar.pack(fill="x", pady=(4, 0))
        self._s_prog_lbl.configure(text="Starting…")
        self._s_set_msg("Sorting your photos…",
                        "Hang tight — this usually only takes a moment.", S_TEXT, S_CARD)
        threading.Thread(target=self._s_do_sort, args=(in_f, out_f), daemon=True).start()

    def _s_do_sort(self, in_f: Path, out_f: Path):
        same   = in_f.resolve() == out_f.resolve()
        action = shutil.move if same else shutil.copy2
        verb   = "Moved" if same else "Copied"
        n_raw = n_jpg = skipped = processed = 0
        try:
            files = [f for f in in_f.iterdir() if f.is_file()]
            total = sum(1 for f in files if f.suffix.lower() in RAW_EXT | JPG_EXT)
            if total == 0:
                self.after(0, self._s_set_msg, "No RAW or JPG files found",
                           "The selected folder doesn't contain any photos to sort.",
                           S_AMBER, S_CARD)
                self.after(0, self._s_reset_sort)
                return
            for f in files:
                ext = f.suffix.lower()
                if ext not in RAW_EXT | JPG_EXT:
                    continue
                d_dir = (out_f / "RAW") if ext in RAW_EXT else (out_f / "JPG")
                d_dir.mkdir(parents=True, exist_ok=True)
                dest = d_dir / f.name
                processed += 1
                self.after(0, self._s_update_prog, processed, total, f.name)
                if dest.exists():
                    skipped += 1
                else:
                    action(str(f), str(dest))
                    if ext in RAW_EXT: n_raw += 1
                    else:              n_jpg += 1
            self.after(0, self._s_set_results, verb, n_raw, n_jpg, skipped, out_f)
        except Exception as e:
            self.after(0, self._s_set_msg, "Something went wrong", str(e), S_RED, S_RED_BG)
        self.after(0, self._s_reset_sort)

    def _s_update_prog(self, cur, total, fname):
        self._s_prog_bar.set(cur / total)
        self._s_prog_lbl.configure(text=f"{fname}   {cur} / {total}")

    def _s_reset_sort(self):
        self._sorting = False
        self._s_prog_bar.pack_forget()
        self._s_prog_lbl.configure(text="")
        self._s_sort_btn.configure(state="normal", text="Sort Photos",
                                    fg_color=S_ACCENT, text_color="#FFFFFF")
        self._s_out_btn.configure(state="normal")


if __name__ == "__main__":
    app = PhotoSorterApp()
    app.mainloop()
