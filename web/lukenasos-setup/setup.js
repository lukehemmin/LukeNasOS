/* LukeNasOS first-boot wizard — step 1.
 *
 * Privilege model (SPEC §6, eng decision 1A): this file contains zero calls
 * to useradd/smbpasswd/nft. Every mutation is a `luke setup` verb spawned
 * with superuser; the one exception the design names is
 * `loginctl terminate-user`, which ends the retired account's session after
 * the interstitial has explained why.
 */
"use strict";

/* global cockpit */

const $ = (id) => document.getElementById(id);

const VIEWS = ["view-loading", "view-noadmin", "view-form", "view-done"];
function show(view) {
    VIEWS.forEach((v) => { $(v).hidden = (v !== view); });
}

/* Run a luke verb with --json. Resolves with the parsed object.
 *
 * Exit 77 is "nothing to do" and carries a normal result object — a
 * re-submitted hostname answers {result:"current"} with 77, and treating
 * that as failure would make the wizard un-resumable. Other failures carry
 * luke's own error JSON on stdout ({error:{code,what,cause,next}}); rethrow
 * that so a field can show `what` instead of an exit status.
 */
function luke(...args) {
    return cockpit.spawn(["luke", ...args, "--json"],
                         { superuser: "require", err: "out" })
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

function route(status) {
    if (status.account && status.account.done) {
        $("done-hostname").textContent = (status.hostname && status.hostname.value) || "not chosen yet";
        $("done-user").textContent = status.account.user || "—";
        const shares = (status.share && status.share.shares) || [];
        if (shares.length)
            $("done-shares").textContent = shares.join(", ");
        show("view-done");
        return;
    }
    if (status.hostname && status.hostname.value)
        $("nas-name").value = status.hostname.value;
    show("view-form");
}

function init() {
    luke("setup", "status")
        .then(route)
        .catch((err) => {
            // "access-denied" is the no-superuser case; anything else still
            // deserves its own words rather than a spinner forever.
            $("noadmin-detail").textContent =
                err.what || err.message || (err.problem ? "(" + err.problem + ")" : "");
            show("view-noadmin");
        });
}

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

function submit(ev) {
    ev.preventDefault();
    const nas = $("nas-name").value.trim();
    const account = $("account-name").value.trim();
    fieldError("err-nas", null);
    fieldError("err-account", null);
    fieldError("err-global", null);

    $("submit").disabled = true;
    $("submit-spinner").hidden = false;
    $("submit-label").textContent = "Setting up…";
    const fail = (id) => (err) => {
        fieldError(id, err);
        $("submit").disabled = false;
        $("submit-spinner").hidden = true;
        $("submit-label").textContent = "Create my account";
        return Promise.reject(new Error("handled"));
    };

    luke("setup", "hostname", "--name", nas)
        .catch(fail("err-nas"))
        .then(() => luke("setup", "account", "--name", account).catch(fail("err-account")))
        .then(() => luke("setup", "stamp", "--step", "2").catch(fail("err-global")))
        .then(() => signOutInterstitial(account))
        .catch(() => { /* already shown on its field */ });
}

document.addEventListener("DOMContentLoaded", () => {
    $("step1").addEventListener("submit", submit);
    $("retry").addEventListener("click", (ev) => {
        ev.preventDefault();
        show("view-loading");
        init();
    });
    init();
});
