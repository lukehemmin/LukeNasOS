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

    if (st.rollback)
        seg("seg-rollback", "ok", "rollback armed ✓");
    else
        seg("seg-rollback", "pending", "rollback target: after first update");

    seg("seg-version", "pending", st.booted || "");
}

function pollStrip() {
    luke(["status"])
        .then(renderStrip)
        .catch(() => { /* the strip is ambient; routing owns error surfaces */ })
        .then(() => window.setTimeout(pollStrip, 15000));
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

/* The landing page: with the stock pages hidden (SPEC §6), this is what
 * :9090 is once setup is done — facts, shares with the addresses that open
 * them, and the strip above. */
function renderLanding(status) {
    const host = state.address || window.location.hostname;
    const nas = (status.hostname && status.hostname.value) || null;
    if (nas)
        $("done-title").textContent = nas + " is ready";
    $("done-hostname").textContent = nas || "not chosen yet";
    $("done-user").textContent = state.user || "—";
    const shares = (status.share && status.share.shares) || [];
    if (shares.length) {
        $("done-share-list").innerHTML = shares.map((s) => {
            const el = document.createElement("li");
            el.textContent = s + " — ";
            const code = document.createElement("code");
            code.textContent = "smb://" + host + "/" + s;
            el.appendChild(code);
            return el.outerHTML;
        }).join("");
    }
    luke(["status"])
        .then((st) => { $("done-version").textContent = st.booted || "—"; })
        .catch(() => { /* the strip poll reports OS state on its own */ });
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

document.addEventListener("DOMContentLoaded", () => {
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
