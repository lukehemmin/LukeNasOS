// The first-boot wizard, in a real browser, the way the owner drives it.
//
// The machine half (verbs, credential transfer, capsule) is proven by the
// lifecycle E2E; what has never executed before this file is the JS itself —
// the form flow, the sign-out interstitial before terminate-user, the
// resume routing. So this suite follows the owner's literal path: sign in
// as 'luke' with the SETUP TOKEN read off the machine, name the NAS and
// the account, get signed out with an explanation, sign back in as
// themselves, and end holding an smb:// address.
//
// One test, in order, one machine: the wizard MUTATES the machine, so
// these steps are not independent and must never run parallel or retried.
//
// Test-environment honesty: the harness kickstart un-expires 'luke', so the
// PAM forced password change never happens here and the token itself rides
// through as the transferred password. In production PAM forces the change
// at first login (SPEC §10) — that PAM screen belongs to Cockpit, not to
// our JS, which is why skipping it here does not skip our code.
"use strict";

const { test, expect } = require("@playwright/test");

const TOKEN = process.env.LUKE_TOKEN;
const ADMIN = "sangho";
const SHARE = "family";

const SCREENS = "screens";

function wizard(page) {
    // Cockpit renders each package in an iframe named
    // "cockpit1:localhost/<package>".
    return page.frameLocator('iframe[name$="lukenasos-setup"]');
}

async function login(page, user, password) {
    // Cockpit sessions start limited, and whether to escalate at login is a
    // per-user browser preference the shell keeps in localStorage. A fresh
    // Playwright profile has no preferences, so seed the one a returning
    // admin's browser would have: with it, the shell escalates with the
    // password being typed right here — the same flow a real owner gets on
    // every visit after their first "Turn on administrative access".
    await page.evaluate((u) => {
        window.localStorage.setItem("superuser:" + u, "sudo");
    }, user);
    await page.fill("#login-user-input", user);
    await page.fill("#login-password-input", password);
    await page.click("#login-button");
}

test("the first-boot wizard, end to end, as the owner", async ({ page }) => {
    test.skip(!TOKEN, "LUKE_TOKEN must carry the machine's setup token");

    await test.step("the login page coaches the token", async () => {
        await page.goto("/");
        // The Banner hook (design finding 2.5): without these words, nothing
        // on this screen hints that the token IS the password.
        await expect(page.getByText(/setup token/i)).toBeVisible({ timeout: 60000 });
        await page.screenshot({ path: `${SCREENS}/01-login-token-hint.png`, fullPage: true });
    });

    await test.step("sign in as luke with the token; step 1 appears", async () => {
        await login(page, "luke", TOKEN);
        // The stock pages are hidden, so the wizard is the only place the
        // shell can land.
        await expect(wizard(page).locator("#view-step1")).toBeVisible({ timeout: 120000 });
        await page.screenshot({ path: `${SCREENS}/02-step1.png`, fullPage: true });
    });

    await test.step("name the NAS and the account", async () => {
        await expect(wizard(page).locator("#nas-name")).toHaveValue("luke-nas");
        await wizard(page).locator("#account-name").fill(ADMIN);
        await wizard(page).locator("#submit-step1").click();
    });

    await test.step("the interstitial explains the sign-out BEFORE it happens", async () => {
        // Design finding 3.2 (CRITICAL): a silent disconnect on the user's
        // first action reads as a crash.
        const inter = wizard(page).locator("#interstitial");
        await expect(inter).toBeVisible({ timeout: 120000 });
        await expect(inter).toContainText(ADMIN);
        await page.screenshot({ path: `${SCREENS}/03-interstitial.png`, fullPage: true });
    });

    await test.step("the session ends; the login page tells the new story", async () => {
        // terminate-user fires after the 5s countdown. Poll by reloading:
        // depending on timing Cockpit shows either its disconnected curtain
        // or the login page, and reload converges both on the login page.
        await page.waitForTimeout(8000);
        await expect(async () => {
            await page.goto("/");
            await expect(page.locator("#login-user-input")).toBeVisible({ timeout: 5000 });
        }).toPass({ timeout: 120000 });
        // The hint changed the moment 'luke' retired: the fresh-install text
        // would now be a lie, and luke setup account rewrote it.
        await expect(page.getByText(/account name and password/i)).toBeVisible({ timeout: 30000 });
        await page.screenshot({ path: `${SCREENS}/04-relogin-hint.png`, fullPage: true });
    });

    await test.step("sign back in as the new account; the wizard resumes at step 2", async () => {
        await login(page, ADMIN, TOKEN);
        await expect(wizard(page).locator("#view-step2")).toBeVisible({ timeout: 120000 });
        await page.screenshot({ path: `${SCREENS}/05-step2-network.png`, fullPage: true });
    });

    await test.step("the network looks right; on to the first share", async () => {
        await wizard(page).locator("#submit-step2").click();
        await expect(wizard(page).locator("#view-step3")).toBeVisible({ timeout: 60000 });
    });

    await test.step("the share form: password confirm, with a working show toggle", async () => {
        await expect(wizard(page).locator("#share-name")).toHaveValue(SHARE);
        const pw = wizard(page).locator("#share-password");
        await pw.fill(TOKEN);
        // The toggle exists because the verb cannot check this password
        // against the Unix one — seeing what you typed is the only defense
        // against a share that rejects the password the Done screen promises.
        await wizard(page).locator("#pw-toggle").click();
        await expect(pw).toHaveAttribute("type", "text");
        await wizard(page).locator("#pw-toggle").click();
        await expect(pw).toHaveAttribute("type", "password");
        await page.screenshot({ path: `${SCREENS}/06-step3-share.png`, fullPage: true });
    });

    await test.step("create the share (the slow one: first image pull)", async () => {
        await wizard(page).locator("#submit-step3").click();
        // Minutes, not a spinner: the page says so, and this timeout agrees.
        await expect(wizard(page).locator("#view-step4")).toBeVisible({ timeout: 15 * 60 * 1000 });
        await expect(wizard(page).locator("#mount-mac")).toContainText("smb://");
        await expect(wizard(page).locator("#mount-mac")).toContainText(SHARE);
        await page.screenshot({ path: `${SCREENS}/07-step4-done.png`, fullPage: true });
    });

    await test.step("finish lands on the landing page, strip and shares included", async () => {
        await wizard(page).locator("#submit-step4").click();
        await expect(wizard(page).locator("#view-done")).toBeVisible({ timeout: 60000 });
        await expect(wizard(page).locator("#done-share-list")).toContainText(SHARE);
        await expect(wizard(page).locator("#strip")).toContainText("factory reset ready", { timeout: 60000 });
    });

    await test.step("the verdict speaks in a sentence and the timeline remembers", async () => {
        // The landing is the dashboard's first slice (DESIGN.md bones #1,
        // #4): verdict as a sentence, then the journal — and the journal's
        // first entries are the wizard's own actions, performed minutes ago
        // in this very test. The machine remembers what just happened to it.
        await expect(wizard(page).locator("#verdict-word")).toContainText(
            "Everything is fine.", { timeout: 60000 });
        const timeline = wizard(page).locator("#timeline");
        await expect(timeline).toContainText("Named the machine “luke-nas”");
        await expect(timeline).toContainText("Created administrator " + ADMIN);
        await expect(timeline).toContainText("Opened share “" + SHARE + "”");
    });

    await test.step("undo is present, honest, and disarmed on a fresh machine", async () => {
        // Bone #5: the undo control is the largest control on the page — but
        // a fresh install has no rollback target, and the button must say so
        // instead of pretending (LUKE-E030 as UI state, not as a surprise).
        await expect(wizard(page).locator("#undo")).toBeDisabled();
        await expect(wizard(page).locator("#undo-hint")).toContainText(
            "arms after your first update");
        await page.screenshot({ path: `${SCREENS}/08-landing.png`, fullPage: true });
    });
});
