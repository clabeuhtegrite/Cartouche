"""The window: the player's folders, their games with what is due and why, and
the batch as it runs. Work runs on a thread of its own; the window only shows
what it reports (Tk is used from the main thread alone)."""

from __future__ import annotations

import queue
import subprocess
import sys
import threading
import time
import traceback
from datetime import datetime
from pathlib import Path

from . import batch, config as configs, schedule, toolchain
from .build import Progress
from .i18n import language, set_language, t
from .planner import Entry, Plan

KIND_KEYS = {"packages": "kind.packages", "nup": "kind.nup", "dump": "kind.dump", "zip": "kind.zip"}


def size_text(size: int) -> str:
    gb = size / 2**30
    return f"{gb:.1f} Go".replace(".", ",") if language() == "fr" else f"{gb:.1f} GB"


def when_text(iso: str) -> str:
    try:
        moment = datetime.fromisoformat(iso).astimezone()
    except ValueError:
        return ""
    return moment.strftime("%d/%m/%y %H:%M") if language() == "fr" else moment.strftime("%Y-%m-%d %H:%M")


def open_path(path: Path) -> None:
    if sys.platform == "darwin":
        subprocess.Popen(["open", str(path)])


class Window:
    def __init__(self, ctx: batch.Context):
        import tkinter as tk
        from tkinter import ttk

        self.tk, self.ttk = tk, ttk
        self.ctx = ctx
        self.events: queue.Queue = queue.Queue()
        self.plan: Plan | None = None
        self.entries: dict[str, Entry] = {}
        self.worker: threading.Thread | None = None
        self.stop = threading.Event()
        self.status: dict[str, str] = {}  # title ID -> what the batch is doing with it

        self.root = tk.Tk()
        self.root.title("Cartouche Builder")
        self.root.geometry("1180x760")
        self.root.minsize(900, 560)
        self.root.protocol("WM_DELETE_WINDOW", self.close)
        self._build()
        self.root.after(100, self._poll)
        self.root.after(300, lambda: self.check(update=False))

    # ---- Layout -----------------------------------------------------------

    def _build(self) -> None:
        tk, ttk = self.tk, self.ttk
        outer = ttk.Frame(self.root, padding=12)
        outer.pack(fill="both", expand=True)

        head = ttk.Frame(outer)
        head.pack(fill="x")
        ttk.Label(head, text="Cartouche Builder", font=("Helvetica", 18, "bold")).pack(side="left")
        self.engine_label = ttk.Label(head, text="")
        self.engine_label.pack(side="left", padx=16)
        self.stop_button = ttk.Button(head, text=t("gui.stop"), command=self.request_stop, state="disabled")
        self.stop_button.pack(side="right")
        self.build_selected_button = ttk.Button(head, text=t("gui.build_selected"), command=self.build_selected)
        self.build_selected_button.pack(side="right", padx=4)
        self.build_due_button = ttk.Button(head, text=t("gui.build_due"), command=self.build_due)
        self.build_due_button.pack(side="right", padx=4)
        self.check_button = ttk.Button(head, text=t("gui.check"), command=lambda: self.check(update=True))
        self.check_button.pack(side="right", padx=4)

        folders = ttk.LabelFrame(outer, text=t("gui.folders"), padding=8)
        folders.pack(fill="x", pady=(10, 6))
        self.folder_vars: dict[str, tk.StringVar] = {}
        for row, (key, kind) in enumerate((("sources", "folder"), ("games", "folder"), ("keys", "file"), ("workspace", "folder"))):
            ttk.Label(folders, text=t(f"config.field.{key}")).grid(row=row, column=0, sticky="w", padx=(0, 8), pady=2)
            var = tk.StringVar(value=getattr(self.ctx.config, key))
            self.folder_vars[key] = var
            entry = ttk.Entry(folders, textvariable=var)
            entry.grid(row=row, column=1, sticky="ew", pady=2)
            entry.bind("<FocusOut>", lambda _e: self.save_folders())
            ttk.Button(folders, text=t("gui.choose"), command=lambda k=key, kd=kind: self.choose(k, kd)).grid(row=row, column=2, padx=(8, 0))
            ttk.Label(folders, text=t(f"gui.hint.{key}"), foreground="#777").grid(row=row, column=3, sticky="w", padx=(8, 0))
        folders.columnconfigure(1, weight=1)

        foot = ttk.Frame(outer)
        foot.pack(side="bottom", fill="x", pady=(8, 0))
        bottom = ttk.Frame(outer)
        bottom.pack(side="bottom", fill="x", pady=(8, 0))
        middle = ttk.PanedWindow(outer, orient="vertical")
        middle.pack(fill="both", expand=True)
        table = ttk.Frame(middle)
        middle.add(table, weight=3)
        columns = ("build", "name", "title_id", "kind", "size", "last", "status")
        self.tree = ttk.Treeview(table, columns=columns, show="headings", selectmode="extended")
        widths = {"build": 64, "name": 260, "title_id": 165, "kind": 100, "size": 80, "last": 180, "status": 420}
        for column in columns:
            self.tree.heading(column, text=t(f"gui.column.{column}"))
            self.tree.column(column, width=widths[column], stretch=column in ("name", "status"), anchor="w")
        self.tree.tag_configure("due", foreground="#0a5fd8")
        self.tree.tag_configure("failed", foreground="#c0392b")
        self.tree.tag_configure("off", foreground="#999")
        self.tree.tag_configure("running", foreground="#b9770e")
        scroll = ttk.Scrollbar(table, orient="vertical", command=self.tree.yview)
        self.tree.configure(yscrollcommand=scroll.set)
        self.tree.pack(side="left", fill="both", expand=True)
        scroll.pack(side="right", fill="y")
        self.tree.bind("<<TreeviewSelect>>", lambda _e: self.show_detail())
        self.tree.bind("<Button-1>", self._click)
        self.tree.bind("<Double-1>", lambda _e: self.open_log())

        lower = ttk.Frame(middle)
        middle.add(lower, weight=2)
        actions = ttk.Frame(lower)
        actions.pack(side="bottom", fill="x", pady=(4, 0))
        self.detail = tk.Text(lower, height=7, wrap="word", relief="flat", borderwidth=0, font="TkDefaultFont", padx=6, pady=4)
        self.detail.pack(fill="both", expand=True)
        self.detail.configure(state="disabled")
        ttk.Button(actions, text=t("gui.open_log"), command=self.open_log).pack(side="left")
        ttk.Label(actions, text=t("gui.aliases")).pack(side="left", padx=(16, 4))
        self.alias_var = tk.StringVar()
        alias_entry = ttk.Entry(actions, textvariable=self.alias_var, width=40)
        alias_entry.pack(side="left")
        alias_entry.bind("<Return>", lambda _e: self.save_aliases())
        alias_entry.bind("<FocusOut>", lambda _e: self.save_aliases())

        self.progress = ttk.Progressbar(bottom, mode="determinate", maximum=1000)
        self.progress.pack(fill="x")
        self.status_label = ttk.Label(bottom, text="")
        self.status_label.pack(fill="x", pady=(4, 0))
        self.log = tk.Text(bottom, height=5, wrap="none", relief="flat", borderwidth=0, foreground="#555", padx=6, pady=4)
        self.log.pack(fill="x", pady=(4, 0))
        self.log.configure(state="disabled")

        self.night_var = tk.BooleanVar(value=self.ctx.config.schedule)
        ttk.Checkbutton(foot, text=t("gui.nightly"), variable=self.night_var, command=self.save_schedule).pack(side="left")
        self.time_var = tk.StringVar(value=f"{self.ctx.config.schedule_hour:02d}:{self.ctx.config.schedule_minute:02d}")
        time_entry = ttk.Entry(foot, textvariable=self.time_var, width=6)
        time_entry.pack(side="left", padx=4)
        time_entry.bind("<FocusOut>", lambda _e: self.save_schedule())
        ttk.Button(foot, text=t("gui.settings"), command=self.open_settings).pack(side="right")
        ttk.Button(foot, text=t("gui.tools"), command=self.open_doctor).pack(side="right", padx=4)
        ttk.Button(foot, text=t("gui.reports"), command=lambda: open_path(self.ctx.paths.reports)).pack(side="right", padx=4)

    # ---- Folders and settings ---------------------------------------------

    def choose(self, key: str, kind: str) -> None:
        from tkinter import filedialog

        current = self.folder_vars[key].get()
        if kind == "file":
            chosen = filedialog.askopenfilename(title=t(f"config.field.{key}"), initialdir=str(Path(current).parent) if current else None)
        else:
            chosen = filedialog.askdirectory(title=t(f"config.field.{key}"), initialdir=current or None, mustexist=True)
        if chosen:
            self.folder_vars[key].set(chosen)
            self.save_folders()

    def save_folders(self) -> None:
        config = self.ctx.config
        changed = False
        for key, var in self.folder_vars.items():
            value = var.get().strip()
            if getattr(config, key) != value:
                setattr(config, key, value)
                changed = True
        if changed:
            configs.save(self.ctx.paths, config)
            problems = config.problems(self.ctx.paths)
            self.set_status("\n".join(problems) if problems else t("gui.saved"))

    def save_schedule(self) -> None:
        config = self.ctx.config
        try:
            hour, minute = (int(x) for x in self.time_var.get().split(":"))
            if not (0 <= hour <= 23 and 0 <= minute <= 59):
                raise ValueError
        except ValueError:
            self.time_var.set(f"{config.schedule_hour:02d}:{config.schedule_minute:02d}")
            return
        config.schedule, config.schedule_hour, config.schedule_minute = self.night_var.get(), hour, minute
        configs.save(self.ctx.paths, config)
        try:
            schedule.sync(self.ctx.paths, config.schedule, hour, minute)
        except OSError as error:
            self.set_status(str(error))

    def save_aliases(self) -> None:
        title_id = self.selected_id()
        if not title_id:
            return
        names = [n.strip() for n in self.alias_var.get().split(",") if n.strip()]
        aliases = dict(self.ctx.config.aliases)
        if names:
            aliases[title_id] = names
        else:
            aliases.pop(title_id, None)
        if aliases != self.ctx.config.aliases:
            self.ctx.config.aliases = aliases
            configs.save(self.ctx.paths, self.ctx.config)

    def open_settings(self) -> None:
        Settings(self)

    def open_doctor(self) -> None:
        Doctor(self)

    # ---- The games --------------------------------------------------------

    def _click(self, event) -> None:
        if self.tree.identify_region(event.x, event.y) != "cell" or self.tree.identify_column(event.x) != "#1":
            return
        title_id = self.tree.identify_row(event.y)
        if not title_id:
            return
        config = self.ctx.config
        if config.only:
            config.only = sorted(set(config.only) ^ {title_id})
        else:
            config.skip = sorted(set(config.skip) ^ {title_id})
        configs.save(self.ctx.paths, config)
        entry = self.entries.get(title_id)
        if entry:
            entry.selected = config.selected(title_id)
            self._row(entry)
        return "break"

    def _row(self, entry: Entry) -> None:
        game, record = entry.game, entry.record
        last = ""
        if record and record.build:
            last = f"{when_text(record.build.built_at)} · {record.build.commit[:8]}"
        status = self.status.get(entry.title_id) or entry.detail
        tag = "running" if entry.title_id in self.status else "off" if not entry.selected else "failed" if entry.reasons[:1] == ["failed_here"] else "due" if entry.build else ""
        values = ("☑" if entry.selected else "☐", game.display_name, entry.title_id, t(KIND_KEYS[game.kind]), size_text(game.size), last, status)
        if self.tree.exists(entry.title_id):
            self.tree.item(entry.title_id, values=values, tags=(tag,))
        else:
            self.tree.insert("", "end", iid=entry.title_id, values=values, tags=(tag,))

    def show_plan(self, plan: Plan) -> None:
        self.plan = plan
        self.entries = {e.title_id: e for e in plan.entries}
        for item in self.tree.get_children():
            if item not in self.entries:
                self.tree.delete(item)
        for entry in plan.entries:
            self._row(entry)
        when = self.ctx.engine.commit_time(plan.head)
        ago = f" · {datetime.fromtimestamp(when).strftime('%d/%m %H:%M')}" if when else ""
        self.engine_label.configure(text=t("gui.engine", commit=plan.head[:12]) + ago)
        due = len(plan.to_build)
        self.set_status(t("gui.planned", games=len(plan.entries), due=due))
        for issue in plan.issues:
            self.add_log("! " + issue)
        for commit, kind, text in plan.notes:
            self.add_log(f"Front-ends {kind} ({commit}): {text}")
        self.show_detail()

    def selected_id(self) -> str | None:
        selection = self.tree.selection()
        return selection[0] if selection else None

    def show_detail(self) -> None:
        title_id = self.selected_id()
        entry = self.entries.get(title_id) if title_id else None
        lines: list[str] = []
        if entry:
            game = entry.game
            lines.append(f"{game.display_name}  [{entry.title_id}]  {t(KIND_KEYS[game.kind])} · {size_text(game.size)}")
            lines.append(str(game.folder if game.kind != "nup" else game.inputs[0]))
            lines.append("")
            lines.append(entry.detail)
            record = entry.record
            if record and record.build:
                build = record.build
                lines.append(t("gui.last_build", date=when_text(build.built_at), commit=build.commit[:12], ipa=build.ipa or "?", origin=t(f"origin.{build.origin}")))
            if record and record.attempt:
                lines.append(t("gui.last_attempt", date=when_text(record.attempt.at), error=record.attempt.error))
            if entry.impact and entry.impact.touched:
                lines.append("")
                lines.append(t("gui.touching"))
                for commit in entry.impact.touching()[-12:]:
                    lines.append(f"  {commit.short}  {commit.subject[:140]}")
            self.alias_var.set(", ".join(self.ctx.config.aliases.get(entry.title_id, [])))
        self.detail.configure(state="normal")
        self.detail.delete("1.0", "end")
        self.detail.insert("1.0", "\n".join(lines))
        self.detail.configure(state="disabled")

    def open_log(self) -> None:
        title_id = self.selected_id()
        if not title_id:
            return
        folder = self.ctx.paths.logs / title_id
        logs = sorted(folder.glob("*.log")) if folder.is_dir() else []
        open_path(logs[-1] if logs else self.ctx.paths.logs)

    # ---- Work -------------------------------------------------------------

    def busy(self) -> bool:
        return self.worker is not None and self.worker.is_alive()

    def _start(self, target, *args) -> None:
        if self.busy():
            return
        self.save_folders()
        self.stop.clear()
        self.status.clear()
        for button in (self.check_button, self.build_due_button, self.build_selected_button):
            button.configure(state="disabled")
        self.stop_button.configure(state="normal")

        def work():
            try:
                target(*args)
            except (batch.Busy, batch.Blocked) as error:
                self.events.put(("status", "", str(error)))
            except Exception as error:  # shown, not swallowed: the window stays usable
                self.events.put(("status", "", f"{type(error).__name__}: {error}"))
                self.events.put(("log", "", traceback.format_exc()))
            finally:
                self.events.put(("idle", "", None))

        self.worker = threading.Thread(target=work, daemon=True)
        self.worker.start()

    def check(self, update: bool) -> None:
        def work():
            with batch.batch_lock(self.ctx.paths):
                plan = batch.survey(self.ctx, update=update, log=lambda m: self.events.put(("log", "", m)))
            self.events.put(("plan", "", plan))

        self.set_status(t("gui.checking"))
        self._start(work)

    def build_due(self) -> None:
        self._start(self._run, None, None)

    def build_selected(self) -> None:
        """Builds the rows picked in the list now, due or not."""
        chosen = set(self.tree.selection())
        if chosen:
            self._start(self._run, chosen, chosen)

    def _run(self, only, force) -> None:
        def follow(kind, title_id, value):
            self.events.put((kind, title_id, value))

        _plan, summary = batch.run_due(self.ctx, update=True, force=force, only=only, on_event=follow, stop=self.stop, log=lambda m: self.events.put(("log", "", m)))
        self.events.put(("summary", "", summary))
        with batch.batch_lock(self.ctx.paths):
            self.events.put(("plan", "", batch.survey(self.ctx, update=False)))

    def request_stop(self) -> None:
        self.stop.set()
        self.set_status(t("gui.stopping"))

    def _poll(self) -> None:
        try:
            while True:
                kind, title_id, value = self.events.get_nowait()
                self._handle(kind, title_id, value)
        except queue.Empty:
            pass
        self.root.after(150, self._poll)

    def _handle(self, kind: str, title_id: str, value) -> None:
        entry = self.entries.get(title_id)
        if kind == "plan":
            self.show_plan(value)
        elif kind == "status":
            self.set_status(value)
        elif kind == "log":
            self.add_log(value)
        elif kind == "idle":
            for button in (self.check_button, self.build_due_button, self.build_selected_button):
                button.configure(state="normal")
            self.stop_button.configure(state="disabled")
            self.status.clear()
            self.progress.configure(value=0)
        elif kind == "start":
            self.status[title_id] = t("gui.starting")
            self.add_log(t("cli.building", name=value.game.display_name, title_id=title_id, why=value.detail))
        elif kind == "progress":
            progress: Progress = value
            self.status[title_id] = progress.text()
            share = progress.overall()
            self.progress.configure(value=int((share or 0) * 1000))
            name = entry.game.display_name if entry else title_id
            eta = f" · {int(progress.eta // 60)} min" if progress.eta else ""
            self.set_status(f"{name}: {progress.text()}{eta}")
        elif kind in ("unpack", "deliver"):
            self.progress.configure(value=int(value * 1000))
        elif kind == "message":
            if value.startswith("[RED] ") or value.startswith("[NOTE] "):
                self.add_log(f"{title_id}: {value}")
            else:
                self.status[title_id] = value
        elif kind == "built":
            self.status.pop(title_id, None)
            self.add_log(t("cli.built", name=value.ipa, minutes=int(value.duration // 60)))
        elif kind == "failed":
            self.status.pop(title_id, None)
            self.add_log(t("cli.failed", error=value))
        elif kind == "summary":
            self.set_status(t("gui.done", built=len(value.built), failed=len(value.failed)))
        if entry is not None:
            self._row(entry)

    def set_status(self, text: str) -> None:
        self.status_label.configure(text=text)

    def add_log(self, text: str) -> None:
        self.log.configure(state="normal")
        self.log.insert("end", f"{time.strftime('%H:%M:%S')}  {text.rstrip()}\n")
        lines = int(self.log.index("end-1c").split(".")[0])
        if lines > 800:
            self.log.delete("1.0", f"{lines - 800}.0")
        self.log.see("end")
        self.log.configure(state="disabled")

    def close(self) -> None:
        if self.busy():
            from tkinter import messagebox

            if not messagebox.askyesno("Cartouche Builder", t("gui.quit_while_building")):
                return
            self.stop.set()
        self.root.destroy()

    def run(self) -> None:
        self.root.mainloop()


class Settings:
    def __init__(self, window: Window):
        tk, ttk = window.tk, window.ttk
        self.window = window
        config = window.ctx.config
        self.top = tk.Toplevel(window.root)
        self.top.title(t("gui.settings"))
        self.top.transient(window.root)
        frame = ttk.Frame(self.top, padding=14)
        frame.pack(fill="both", expand=True)
        row = 0
        ttk.Label(frame, text=t("settings.policy"), font=("Helvetica", 13, "bold")).grid(row=row, column=0, columnspan=3, sticky="w")
        row += 1
        self.policy = tk.StringVar(value=config.engine_policy)
        for value in configs.POLICIES:
            ttk.Radiobutton(frame, text=t(f"settings.policy.{value}"), value=value, variable=self.policy).grid(row=row, column=0, columnspan=3, sticky="w")
            row += 1
        self.numbers: dict[str, tk.StringVar] = {}
        for key, low, high in (("refresh_days", 1, 365), ("jobs", 1, 4), ("min_free_gb", 0, 10000), ("workspace_limit_gb", 0, 100000)):
            ttk.Label(frame, text=t(f"settings.{key}")).grid(row=row, column=0, sticky="w", pady=2)
            var = tk.StringVar(value=str(getattr(config, key)))
            self.numbers[key] = var
            ttk.Spinbox(frame, from_=low, to=high, textvariable=var, width=8).grid(row=row, column=1, sticky="w")
            row += 1
        ttk.Label(frame, text=t("settings.game_language")).grid(row=row, column=0, sticky="w", pady=2)
        self.game_language = tk.StringVar(value=config.game_language)
        ttk.Combobox(frame, textvariable=self.game_language, values=("", "fr", "en-GB", "de", "es", "it", "nl", "pt", "ja", "ko", "zh-Hans", "zh-Hant", "fr-CA", "es-419", "pt-BR", "ru"), width=10).grid(row=row, column=1, sticky="w")
        row += 1
        ttk.Label(frame, text=t("settings.language")).grid(row=row, column=0, sticky="w", pady=2)
        self.language = tk.StringVar(value=config.language)
        ttk.Combobox(frame, textvariable=self.language, values=("", "fr", "en"), width=10, state="readonly").grid(row=row, column=1, sticky="w")
        row += 1
        self.flags: dict[str, tk.BooleanVar] = {}
        for key in ("notifications", "keep_ipa", "unprofiled"):
            var = tk.BooleanVar(value=getattr(config, key))
            self.flags[key] = var
            ttk.Checkbutton(frame, text=t(f"settings.{key}"), variable=var).grid(row=row, column=0, columnspan=3, sticky="w", pady=2)
            row += 1
        self.message = ttk.Label(frame, text="", foreground="#c0392b")
        self.message.grid(row=row, column=0, columnspan=3, sticky="w")
        row += 1
        buttons = ttk.Frame(frame)
        buttons.grid(row=row, column=0, columnspan=3, sticky="e", pady=(10, 0))
        ttk.Button(buttons, text=t("gui.cancel"), command=self.top.destroy).pack(side="right")
        ttk.Button(buttons, text=t("gui.save"), command=self.save).pack(side="right", padx=4)

    def save(self) -> None:
        config = self.window.ctx.config
        before = configs.Config(**vars(config))
        try:
            config.engine_policy = self.policy.get()
            for key, var in self.numbers.items():
                setattr(config, key, int(var.get()))
            config.game_language = self.game_language.get().strip()
            config.language = self.language.get().strip()
            for key, var in self.flags.items():
                setattr(config, key, var.get())
            configs.save(self.window.ctx.paths, config)
        except ValueError as error:
            for key, value in vars(before).items():
                setattr(config, key, value)
            self.message.configure(text=str(error) if str(error) else t("settings.invalid"))
            return
        if config.language != before.language:
            set_language(config.language or None)
            self.window.set_status(t("settings.restart"))
        self.top.destroy()


class Doctor:
    def __init__(self, window: Window):
        tk, ttk = window.tk, window.ttk
        self.window = window
        self.top = tk.Toplevel(window.root)
        self.top.title(t("gui.tools"))
        self.top.transient(window.root)
        self.frame = ttk.Frame(self.top, padding=14)
        self.frame.pack(fill="both", expand=True)
        ttk.Label(self.frame, text=t("doctor.checking")).pack()
        threading.Thread(target=self._check, daemon=True).start()

    def _check(self) -> None:
        ctx = self.window.ctx
        checks = toolchain.doctor(ctx.paths, ctx.engine.root if ctx.engine.present else None)
        self.window.root.after(0, lambda: self._show(checks))

    def _show(self, checks) -> None:
        ttk = self.window.ttk
        for child in self.frame.winfo_children():
            child.destroy()
        for row, check in enumerate(checks):
            mark = "✓" if check.ok else ("✗" if check.blocking else "·")
            ttk.Label(self.frame, text=mark, foreground="#1e8449" if check.ok else "#c0392b").grid(row=row, column=0, sticky="nw", padx=(0, 6))
            text = f"{t(f'check.{check.key}')}: {check.found or t('cli.not_found')}"
            if not check.ok:
                text += f"\n{check.fix}"
            ttk.Label(self.frame, text=text, wraplength=560, justify="left").grid(row=row, column=1, sticky="w", pady=3)
            if not check.ok and check.command:
                ttk.Button(self.frame, text=t("doctor.terminal"), command=lambda c=check.command: toolchain.open_in_terminal(c)).grid(row=row, column=2, padx=(8, 0))
        buttons = ttk.Frame(self.frame)
        buttons.grid(row=len(checks), column=0, columnspan=3, sticky="e", pady=(12, 0))
        ttk.Button(buttons, text=t("gui.close"), command=self.top.destroy).pack(side="right")
        ttk.Button(buttons, text=t("doctor.setup"), command=self.setup).pack(side="right", padx=4)
        ttk.Button(buttons, text=t("doctor.again"), command=lambda: threading.Thread(target=self._check, daemon=True).start()).pack(side="right", padx=4)

    def setup(self) -> None:
        window = self.window

        def work():
            ctx = window.ctx
            with batch.batch_lock(ctx.paths):
                window.events.put(("log", "", t("batch.cloning_engine") if not ctx.engine.present else t("batch.updating_engine")))
                ctx.engine.update()
                toolchain.ensure_python(ctx.paths, ctx.engine.requirements, log=lambda m: window.events.put(("log", "", m)))
                toolchain.write_dotnet_lock(ctx.paths)
            window.events.put(("status", "", t("cli.setup_done")))

        self.top.destroy()
        window._start(work)


def main(ctx: batch.Context) -> int:
    import importlib.util

    if importlib.util.find_spec("tkinter") is None:
        print(t("gui.no_tk"), file=sys.stderr)
        return 1
    if ctx.config.schedule:
        try:
            schedule.sync(ctx.paths, True, ctx.config.schedule_hour, ctx.config.schedule_minute)
        except OSError:
            pass
    Window(ctx).run()
    return 0
