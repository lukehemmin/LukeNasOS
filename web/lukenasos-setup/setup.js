/* LukeNasOS first-boot wizard — Account → Network → First share → Done.
 *
 * Privilege model (SPEC §6, eng decision 1A): this file contains zero calls
 * to system administration tools. Every mutation is a `luke setup` verb
 * spawned with superuser; the two non-luke spawns are the ones the design
 * names — a read-only `ip addr` for the network view, and
 * `loginctl terminate-user` after the interstitial has explained why the
 * session is about to end.
 */
"use strict";

/* global cockpit */

const $ = (id) => document.getElementById(id);

const VIEWS = ["view-loading", "view-noadmin", "view-step1", "view-step2",
               "view-step3", "view-step4", "view-done"];
const STEP_OF = { "view-step1": 1, "view-step2": 2, "view-step3": 3, "view-step4": 4 };
const STEP_NAMES = ["Account", "Network", "First share", "Done"];

/* What the wizard learned at routing time, reused by later steps. */
const state = { user: null, share: null, address: null };

/* Set once the owner completes an undo, so the live poll stops re-arming the
 * control: its "Returned. vX boots next." message must survive every refresh,
 * and re-arming would offer the double-undo the undo verb warns against.
 * undoHolding guards the ~900ms press itself — a poll landing mid-hold must
 * not let armUndo reset the button out from under the finger. */
let undoDone = false;
let undoHolding = false;

function renderPills(current) {
    $("pills").innerHTML = STEP_NAMES.map((n, i) => {
        const cls = (i + 1 === current) ? "pill current" : "pill";
        return '<span class="' + cls + '">' + (i + 1) + " · " + n + "</span>";
    }).join("");
    $("pills-compact").textContent =
        current ? "Step " + current + " of 4 — " + STEP_NAMES[current - 1] : "";
}

function show(view) {
    VIEWS.forEach((v) => { $(v).hidden = (v !== view); });
    renderPills(STEP_OF[view] || 0);
}

/* Run a luke verb with --json. Resolves with the parsed object.
 *
 * Exit 77 is "nothing to do" and carries a normal result object — a resumed
 * wizard re-submitting a hostname answers {result:"current"} with 77, and
 * treating that as failure would make the wizard un-resumable. Other
 * failures carry luke's own error JSON on stdout
 * ({error:{code,what,cause,next}}); rethrow that so a field can show `what`
 * instead of an exit status.
 */
function luke(args, options) {
    return cockpit.spawn(["luke"].concat(args, ["--json"]),
                         Object.assign({ superuser: "require", err: "out" }, options || {}))
        .then((out) => JSON.parse(out))
        .catch((ex, out) => {
            if (ex.exit_status === 77 && out) return JSON.parse(out);
            let parsed = null;
            try { parsed = JSON.parse(out).error; } catch (e) { /* not luke's JSON */ }
            return Promise.reject(parsed || ex);
        });
}

function fieldError(id, err) {
    const el = $(id);
    if (err) {
        // luke's error contract: what (the sentence), next (the remediation).
        el.textContent = err.what ? err.what + (err.next ? " — " + err.next : "")
                                  : (err.message || String(err));
        el.hidden = false;
    } else {
        el.hidden = true;
    }
}

function busy(button, on, label) {
    button.disabled = on;
    button.querySelector(".spinner").hidden = !on;
    if (label)
        button.querySelector(".btn-label").textContent = label;
}

function mountStrings(share) {
    const host = state.address || window.location.hostname;
    $("mount-win").textContent = "\\\\" + host + "\\" + share;
    $("mount-mac").textContent = "smb://" + host + "/" + share;
    $("done4-user").textContent = state.user || "—";
}

/* ── the health strip ────────────────────────────────────────────────── */

/* Polls, rather than reads once: a segment flipping to its strong form
 * mid-wizard is a live proof, not a static claim (design finding 3.4). Every
 * failure state names the command that explains it — no dead ends. */
function seg(id, cls, text) {
    const el = $(id);
    el.className = "seg " + cls;
    el.textContent = text;
}

function renderStrip(st) {
    $("strip").hidden = false;
    if (st.verdict === "OK")
        seg("seg-verdict", "ok", "● OK");
    else if (st.verdict === "RECOVERED")
        seg("seg-verdict", "warn", "▲ recovered — an update was rolled back");
    else
        seg("seg-verdict", "bad", "✕ degraded — luke doctor");

    if (st.pinned)
        seg("seg-reset", "ok", "factory reset ready ✓");
    else
        seg("seg-reset", "bad", "factory reset target missing — luke doctor");

    if (st.rollback && st.rollback_blocked)
        // The rollback slot holds the version that just failed here — real,
        // but not somewhere to go. Neutral, not a green "armed ✓" that the
        // disabled undo below would then contradict.
        seg("seg-rollback", "pending", "previous version set aside");
    else if (st.rollback)
        seg("seg-rollback", "ok", "rollback armed ✓");
    else
        seg("seg-rollback", "pending", "rollback target: after first update");

    seg("seg-version", "pending", st.booted || "");
}

/* The dashboard is live, not a snapshot: the same 15s tick that keeps the
 * strip honest also re-renders the landing when it is showing, so an update
 * that stages, applies, or rolls itself back while the owner is watching
 * appears without a manual reload — the "live proof, not a static claim"
 * principle (design finding 3.4), extended from the strip to the whole page.
 *
 * On the landing, ONE status --events fetch feeds the strip AND the verdict/
 * timeline/undo (refreshLanding renders the strip too). The first cut fetched
 * status twice per tick — once for the strip, once for the landing — and a
 * state change (an ack) landing between them left the strip and the verdict
 * disagreeing for a whole tick, which a real machine caught. During the wizard
 * steps view-done is hidden and only the strip refreshes, on its own fetch. */
function pollStrip() {
    const onLanding = !$("view-done").hidden;
    const done = () => window.setTimeout(pollStrip, 15000);
    if (onLanding) {
        // Never re-arm mid-hold (a poll must not reset the button under the
        // finger) or after a completed undo (its confirmation must survive).
        refreshLanding(!undoDone && !undoHolding)
            .then(() => renderStorage())
            .catch(() => {})
            .then(done);
        return;
    }
    luke(["status"])
        .then(renderStrip)
        .catch(() => { /* the strip is ambient; routing owns error surfaces */ })
        .then(done);
    // .catch().then(), not .finally(): cockpit's promise flavor predates it.
}

/* ── routing ─────────────────────────────────────────────────────────── */

/* Where the LAN finds this machine — the same source the console banner
 * reads. Falls back to the address the browser itself used, which is by
 * definition one that works from that browser. */
function fetchAddress() {
    return cockpit.spawn(["ip", "-j", "-4", "addr", "show", "scope", "global", "up"],
                         { err: "message" })
        .then((out) => {
            const ifaces = JSON.parse(out).filter((i) => (i.addr_info || []).length);
            if (ifaces.length)
                state.address = ifaces[0].addr_info[0].local;
        })
        .catch(() => { /* the fallback covers it */ });
}

/* ── the landing: verdict, timeline, undo (DESIGN.md bones #1, #4, #5) ── */

/* Each journal entry, said as a person would say it. Unknown types fall
 * through verbatim — a new verb's events must never be invisible. */
const EVENT_TEXT = {
    "installed": () => "LukeNasOS was installed — the story starts here",
    "setup-hostname": (d) => "Named the machine “" + (d.hostname || "?") + "”",
    "setup-account": (d) => "Created administrator " + (d.user || "?"),
    "setup-share": (d) => "Opened share “" + (d.share || d.name || "?") + "”",
    "update-staged": (d) => "Staged update " + (d.version || "") +
        " — applies on the reboot you choose",
    "update-applied": (d) => "Updated to " + (d.version || "a new version"),
    "reboot-to-apply": () => "Rebooted to apply the update",
    "auto-rollback": (d) => "Rolled back automatically after failed health checks" +
        (d.to_version ? " — running " + d.to_version : ""),
    "undo": (d) => "Returned to " + (d.version || "the previous version"),
    "factory-reset-started": () => "Factory reset started — /data untouched",
    "factory-reset-deployed": () => "Factory reset restored the install image",
    "identity-applied": () => "Restored this machine's identity from its data",
    "console_unlocked": () => "Unlocked the full console",
    "recovery-pinned": () => "Protected the install image as the reset target",
};
const EVENT_DOT = {
    "auto-rollback": "warn",
    "factory-reset-started": "warn",
    "factory-reset-deployed": "warn",
    "update-applied": "ok",
    "undo": "ok",
    "setup-hostname": "ok",
    "setup-account": "ok",
    "setup-share": "ok",
    "identity-applied": "ok",
};

function renderVerdict(st) {
    const word = $("verdict-word");
    if (st.verdict === "OK") {
        word.className = "verdict-word ok";
        word.textContent = "Everything is fine.";
        $("verdict-plain").textContent = st.staged
            ? "An update is staged; it applies on the reboot you choose."
            : "Running the version this machine booted with, all checks passing.";
    } else if (st.verdict === "RECOVERED") {
        const to = (st.last_rollback && st.last_rollback.to_version) || st.booted;
        word.className = "verdict-word warn";
        word.textContent = "Recovered itself. Nothing was lost.";
        $("verdict-plain").textContent =
            "An update failed its health checks and was rolled back " +
            "automatically" + (to ? " — running " + to : "") +
            ". Your data volume was never touched.";
    } else {
        word.className = "verdict-word bad";
        word.textContent = "Something needs attention.";
        $("verdict-plain").textContent =
            "Your data is still served. Run luke doctor over ssh for the " +
            "exact next step.";
    }
    $("verdict-meta").textContent = "booted " + (st.booted || "unknown") +
        (st.staged ? " · staged " + st.staged : "") +
        (st.rollback ? " · rollback target " + st.rollback : "");
}

function renderTimeline(events) {
    const list = $("timeline");
    list.textContent = "";
    if (!events || !events.length) {
        const li = document.createElement("li");
        li.className = "muted";
        li.textContent = "No events recorded yet.";
        list.appendChild(li);
        return;
    }
    // Newest first: the question is "what just happened", not "how it began".
    events.slice().reverse().forEach((ev) => {
        const li = document.createElement("li");
        const dot = document.createElement("span");
        dot.className = "event-dot " + (EVENT_DOT[ev.type] || "");
        const what = document.createElement("p");
        what.className = "event-what";
        const say = EVENT_TEXT[ev.type];
        what.textContent = say ? say(ev.detail || {}) : ev.type;
        const meta = document.createElement("p");
        meta.className = "event-meta";
        const d = ev.detail || {};
        const facts = [(ev.ts || "").replace("T", " ").replace("Z", "")];
        if (d.version) facts.push(d.version);
        if (d.digest) facts.push(String(d.digest).slice(0, 19));
        meta.textContent = facts.filter(Boolean).join(" · ");
        li.appendChild(dot);
        li.appendChild(what);
        li.appendChild(meta);
        list.appendChild(li);
    });
}

/* Hold-to-run (bone #5): ~900ms hold, drain on release, no modal. The
 * machine's own guards (LUKE-E030/31/32) are the safety net — their `what`
 * sentence lands in the hint, never a dead end. */
function armUndo(st) {
    const btn = $("undo");
    const hint = $("undo-hint");
    btn.classList.remove("holding", "done");
    if (st.staged) {
        btn.disabled = true;
        $("undo-label").textContent = "Return to the previous version";
        hint.textContent = "An update is staged; undo would be ambiguous. " +
            "Reboot to apply it first.";
        return;
    }
    if (!st.rollback) {
        btn.disabled = true;
        $("undo-label").textContent = "Return to the previous version";
        hint.textContent = "Nothing to return to yet — the rollback target " +
            "arms after your first update.";
        return;
    }
    if (st.rollback_blocked) {
        // After a recovery the rollback slot holds the version that just
        // failed here. Offering to return to it would undo the recovery, so
        // the button stays down and says why (the undo verb refuses it too).
        btn.disabled = true;
        $("undo-label").textContent = "Return to the previous version";
        hint.textContent = "The previous version failed its health checks on " +
            "this machine and was set aside — there is nothing safe to return " +
            "to right now.";
        return;
    }
    btn.disabled = false;
    $("undo-label").textContent = "Return to " + st.rollback;
    hint.textContent = "Hold to run — let go anytime and nothing happens.";
}

function wireUndo() {
    const btn = $("undo");
    const hint = $("undo-hint");
    let timer = null;
    const start = (ev) => {
        if (btn.disabled || btn.classList.contains("done")) return;
        ev.preventDefault();
        undoHolding = true;
        btn.classList.add("holding");
        timer = window.setTimeout(() => {
            undoHolding = false;
            btn.classList.remove("holding");
            btn.disabled = true;
            luke(["undo"])
                .then((res) => {
                    undoDone = true;
                    btn.classList.add("done");
                    $("undo-label").textContent =
                        "Returned. " + (res.boots_next || "The previous version") +
                        " boots next.";
                    hint.textContent = "Reboot when you like — the journal " +
                        "below already recorded it.";
                    refreshLanding(false);
                })
                .catch((err) => {
                    btn.disabled = false;
                    hint.textContent = (err && err.what)
                        ? err.what + (err.next ? " — " + err.next : "")
                        : "Undo failed — luke status over ssh has the story.";
                });
        }, 900);
    };
    const cancel = () => {
        undoHolding = false;
        btn.classList.remove("holding");
        if (timer) { window.clearTimeout(timer); timer = null; }
    };
    btn.addEventListener("pointerdown", start);
    btn.addEventListener("pointerup", cancel);
    btn.addEventListener("pointerleave", cancel);
    btn.addEventListener("keydown", (ev) => {
        if ((ev.key === " " || ev.key === "Enter") && !ev.repeat) start(ev);
    });
    btn.addEventListener("keyup", cancel);
}

/* One status --events call feeds the strip, the verdict, the timeline, the
 * undo state, and the version fact — all from the SAME snapshot, so the strip
 * and the verdict can never disagree within a tick (the bug a real machine
 * caught: two fetches straddling an ack). The luke verbs stay the only
 * privileged API.
 *
 * rearm=false after a successful undo: re-arming would offer to undo again,
 * and a second undo re-activates the exact version just escaped (the undo
 * verb warns of this itself). The completed button keeps its "Returned"
 * message; only the timeline refreshes to show the new event. */
function refreshLanding(rearm) {
    return luke(["status", "--events"])
        .then((st) => {
            renderStrip(st);
            renderVerdict(st);
            renderTimeline(st.events);
            if (rearm !== false) armUndo(st);
            $("done-version").textContent = st.booted || "—";
        })
        .catch(() => {
            $("verdict-word").className = "verdict-word";
            $("verdict-word").textContent = "Status is unavailable.";
            $("verdict-plain").textContent =
                "luke status over ssh still has the story.";
        });
}

/* Bytes as a person reads them — IEC (1024), matching the verb's numfmt. */
function humanBytes(n) {
    if (n === null || n === undefined) return "—";
    const units = ["B", "KB", "MB", "GB", "TB", "PB"];
    let i = 0;
    let v = n;
    while (v >= 1024 && i < units.length - 1) { v /= 1024; i += 1; }
    const shown = (i === 0 || v >= 100) ? Math.round(v) : Math.round(v * 10) / 10;
    return shown + " " + units[i];
}

/* Storage is supporting evidence (DESIGN.md), so a failure hides the panel
 * rather than shouting: the verdict and timeline above carry the machine's
 * health, and a NAS that cannot read its own df is a luke doctor problem, not
 * a landing-page one. */
function renderStorage() {
    return luke(["storage"])
        .then((s) => {
            const d = s.data;
            if (!d || !d.total_bytes) { $("storage").hidden = true; return; }
            const pct = Math.max(0, Math.min(100, d.percent_used));
            const fill = $("storage-fill");
            fill.style.width = pct + "%";
            fill.classList.toggle("pressure", !!(s.pool && s.pool.pressure));
            $("storage-figure").textContent =
                humanBytes(d.used_bytes) + " of " + humanBytes(d.total_bytes) +
                " (" + d.percent_used + "%)";
            const note = $("storage-note");
            if (s.pool && s.pool.pressure) {
                note.textContent = "Pool space is tight — run luke doctor over ssh.";
                note.hidden = false;
            } else {
                note.hidden = true;
            }
            $("storage").hidden = false;
        })
        .catch(() => { $("storage").hidden = true; });
}

/* The landing page: with the stock pages hidden (SPEC §6), this is what
 * :9090 is once setup is done — the verdict as a sentence, the timeline,
 * the undo control, then the machine's facts, storage, and shares. */
function renderLanding(status) {
    const host = state.address || window.location.hostname;
    const nas = (status.hostname && status.hostname.value) || null;
    if (nas)
        $("done-title").textContent = nas + " is ready";
    $("done-hostname").textContent = nas || "not chosen yet";
    $("done-user").textContent = state.user || "—";
    const shares = (status.share && status.share.shares) || [];
    if (shares.length) {
        const list = $("done-share-list");
        list.textContent = "";
        shares.forEach((s) => {
            const el = document.createElement("li");
            el.textContent = s + " — ";
            const code = document.createElement("code");
            code.textContent = "smb://" + host + "/" + s;
            el.appendChild(code);
            list.appendChild(el);
        });
    }
    refreshLanding();
    renderStorage();
    show("view-done");
}

function route(status) {
    state.user = (status.account && status.account.user) || null;
    const shares = (status.share && status.share.shares) || [];
    state.share = shares[0] || null;

    if (status.complete) {
        fetchAddress().then(() => renderLanding(status));
        return;
    }

    if (!(status.account && status.account.done)) {
        if (status.hostname && status.hostname.value)
            $("nas-name").value = status.hostname.value;
        show("view-step1");
        return;
    }

    // Account exists (this wizard's step 1, or an interactive install that
    // already made a wheel user — either way, never show a form that was
    // already submitted). The bookmark decides between 2 and 3; a machine
    // with an account but no bookmark still starts at 2.
    $("share-owner").textContent = state.user;
    const step = (status.wizard && status.wizard.step) || "2";
    if (step === "3") {
        show("view-step3");
    } else {
        show("view-step2");
        loadNetwork();
    }
}

/* Ask the bridge to become root, explicitly. The shell normally escalates
 * an admin's session at login, but it does so asynchronously — this page's
 * first spawn can race it and lose (observed: a fresh login landing on the
 * "administrative access" screen that a reload fixed). Where sudo needs no
 * interaction the Start call succeeds silently; where it would need a
 * password, the shell's own flow is the right place and this call just
 * fails quietly into the retry below. */
function requestSuperuser() {
    return new Promise((resolve) => {
        // The timeout is the contract: where sudo would need a password, the
        // Start call parks on a prompt nobody here can answer (the shell's
        // dialog is the right place for that), and a promise that never
        // settles would freeze the whole retry loop on the loading screen —
        // observed. Resolving is always safe; the caller only retries.
        window.setTimeout(() => resolve(false), 5000);
        try {
            const proxy = cockpit.dbus(null, { bus: "internal" })
                .proxy("cockpit.Superuser", "/superuser");
            proxy.wait(() => {
                if (proxy.Current && proxy.Current !== "none") {
                    resolve(true);
                    return;
                }
                proxy.call("Start", ["sudo"])
                    .then(() => resolve(true), () => resolve(false));
            });
        } catch (e) {
            resolve(false);
        }
    });
}

let initTries = 0;

function init() {
    luke(["setup", "status"])
        .then(route)
        .catch((err) => {
            const denied = err.problem === "access-denied"
                || /not permitted/i.test(err.message || "")
                || /access denied/i.test(err.message || "");
            if (denied && initTries < 8) {
                initTries += 1;
                requestSuperuser().then(() => window.setTimeout(init, 3000));
                return;
            }
            // Still denied after asking, or something else entirely: name it,
            // never a spinner forever.
            $("noadmin-detail").textContent =
                err.what || err.message || (err.problem ? "(" + err.problem + ")" : "");
            show("view-noadmin");
        });
}

/* ── step 1: account ─────────────────────────────────────────────────── */

/* The order is the design (finding 3.2): stamp progress FIRST, then render
 * the interstitial, and only then terminate the retired account's session —
 * a silent disconnect on the user's first action reads as a crash, and a
 * stamp written after the terminate would never be written at all. */
function signOutInterstitial(name) {
    $("inter-name").textContent = name;
    $("inter-name2").textContent = name;
    $("interstitial").hidden = false;
    let n = 5;
    const tick = window.setInterval(() => {
        n -= 1;
        $("inter-count").textContent = String(n);
        if (n <= 0) {
            window.clearInterval(tick);
            cockpit.spawn(["loginctl", "terminate-user", "luke"],
                          { superuser: "require", err: "ignore" });
            // No .then(): this session is among the things being terminated.
        }
    }, 1000);
}

function submitStep1(ev) {
    ev.preventDefault();
    const nas = $("nas-name").value.trim();
    const account = $("account-name").value.trim();
    ["err-nas", "err-account", "err-step1"].forEach((id) => fieldError(id, null));

    const button = $("submit-step1");
    busy(button, true, "Setting up…");
    const fail = (id) => (err) => {
        fieldError(id, err);
        busy(button, false, "Create my account");
        return Promise.reject(new Error("handled"));
    };

    luke(["setup", "hostname", "--name", nas])
        .catch(fail("err-nas"))
        .then(() => luke(["setup", "account", "--name", account]).catch(fail("err-account")))
        .then(() => luke(["setup", "stamp", "--step", "2"]).catch(fail("err-step1")))
        .then(() => signOutInterstitial(account))
        .catch(() => { /* already shown on its field */ });
}

/* ── step 2: network, read-only ──────────────────────────────────────── */

function loadNetwork() {
    // Read-only, the same source the console banner reads. Mutating the
    // network from the wizard is deliberately not designed yet (SPEC §9).
    cockpit.spawn(["ip", "-j", "-4", "addr", "show", "scope", "global", "up"],
                  { err: "message" })
        .then((out) => {
            const ifaces = JSON.parse(out).filter((i) => (i.addr_info || []).length);
            if (!ifaces.length) {
                $("net-state").textContent =
                    "Not connected yet — check the cable. This page keeps working; " +
                    "the share you make next becomes reachable once the network is.";
                return;
            }
            state.address = ifaces[0].addr_info[0].local;
            $("net-state").textContent =
                "This is where your other devices will find it:";
            const facts = $("net-facts");
            facts.innerHTML = ifaces.map((i) =>
                "<dt>" + i.ifname + "</dt><dd>" +
                i.addr_info.map((a) => a.local).join(", ") + "</dd>").join("");
            facts.hidden = false;
        })
        .catch((ex) => {
            // Never a dead end: name the fallback the user can trust.
            $("net-state").textContent =
                "Could not read the network configuration (" +
                (ex.message || ex.problem || "unknown") +
                ") — `luke status` on the console shows it.";
        });
}

function submitStep2(ev) {
    ev.preventDefault();
    const button = $("submit-step2");
    busy(button, true);
    luke(["setup", "stamp", "--step", "3"])
        .then(() => { busy(button, false); show("view-step3"); })
        .catch(() => { busy(button, false); show("view-step3"); });
    // A failed stamp must not strand the user on step 2: the bookmark is a
    // convenience, and status-derived routing recovers either way.
}

/* ── step 3: the first share ─────────────────────────────────────────── */

function submitStep3(ev) {
    ev.preventDefault();
    const share = $("share-name").value.trim();
    const password = $("share-password").value;
    ["err-share", "err-password", "err-step3"].forEach((id) => fieldError(id, null));
    if (!password) {
        fieldError("err-password", { what: "Confirm your password to turn on file sharing" });
        return;
    }

    const button = $("submit-step3");
    busy(button, true, "Creating the share…");
    $("share-progress").hidden = false;

    const proc = cockpit.spawn(
        ["luke", "setup", "share", "--name", share, "--user", state.user,
         "--password-stdin", "--json"],
        { superuser: "require", err: "out" });
    proc.input(password);
    proc.then((out) => JSON.parse(out))
        .catch((ex, out) => {
            if (ex.exit_status === 77 && out) return JSON.parse(out);
            let parsed = null;
            try { parsed = JSON.parse(out).error; } catch (e) { /* not luke's JSON */ }
            return Promise.reject(parsed || ex);
        })
        .then((result) => luke(["setup", "stamp", "--step", "done"])
            .catch(() => null)
            .then(() => result))
        .then((result) => {
            state.share = result.share || share;
            $("share-progress").hidden = true;
            busy(button, false, "Create the share");
            mountStrings(state.share);
            show("view-step4");
        })
        .catch((err) => {
            // The verb's contract: nothing half-made — no share recorded, 445
            // still shut. So a plain retry is honest.
            $("share-progress").hidden = true;
            busy(button, false, "Create the share");
            fieldError("err-step3", err);
        });
}

function submitStep4(ev) {
    ev.preventDefault();
    init();  // re-routes to the completed view from real status
}

/* ── wiring ──────────────────────────────────────────────────────────── */

/* A user theme is one CSS file that redefines --ln-* token values
 * (DESIGN.md § Theming). It is read through cockpit's channel — the page
 * itself has no filesystem — and injected after setup.css so its :root
 * wins. Absent file, absent style: the default theme IS the absence. */
function loadUserTheme() {
    cockpit.file("/etc/lukenasos/theme.css").read()
        .then((content) => {
            if (!content) return;
            const style = document.createElement("style");
            style.id = "user-theme";
            style.textContent = content;
            document.head.appendChild(style);
        })
        .catch(() => { /* no theme file is the normal case */ });
}

document.addEventListener("DOMContentLoaded", () => {
    loadUserTheme();
    wireUndo();
    $("form-step1").addEventListener("submit", submitStep1);
    $("form-step2").addEventListener("submit", submitStep2);
    $("form-step3").addEventListener("submit", submitStep3);
    $("form-step4").addEventListener("submit", submitStep4);
    $("pw-toggle").addEventListener("click", () => {
        const pw = $("share-password");
        const showing = pw.type === "text";
        pw.type = showing ? "password" : "text";
        $("pw-toggle").textContent = showing ? "Show" : "Hide";
        $("pw-toggle").setAttribute("aria-label",
                                    showing ? "Show password" : "Hide password");
    });
    $("retry").addEventListener("click", (ev) => {
        ev.preventDefault();
        show("view-loading");
        init();
    });
    init();
    pollStrip();
});
