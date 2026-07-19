// The armed undo, held by a real finger.
//
// wizard.spec.js ends on the landing page with the undo control correctly
// DISABLED — a fresh install has one deployment and nothing to go back to.
// This suite is the other half: the harness has since staged an update and
// applied it (v1 → v2), so v1 is now the rollback target, and the largest
// control on the page is live. This drives it the way the owner would — press
// and hold — and proves the two things the disabled test cannot:
//
//   1. Releasing early does nothing (the "you can always let go" promise).
//   2. Holding it to completion runs `luke undo` for real.
//
// The machine-side proof (that the button actually moved the OS back a
// version) is the harness's job: it reboots after this suite and asserts the
// box booted v1. Here we prove the browser did its part — the verb ran, the
// button confirmed, and the journal recorded the return.
//
// One test, one machine, no retries or parallelism: like the wizard, this
// mutates the machine (it stages a rollback), so a second attempt would meet
// a different machine. Guarded on LUKE_UNDO_ARMED so a bare `playwright test`
// against a fresh box skips it instead of failing on a disabled button.
"use strict";

const { test, expect } = require("@playwright/test");

const TOKEN = process.env.LUKE_TOKEN;
const OWNER = process.env.LUKE_OWNER || "sangho";
const ARMED = process.env.LUKE_UNDO_ARMED;

const SCREENS = "screens";

function wizard(page) {
    return page.frameLocator('iframe[name$="lukenasos-setup"]');
}

async function login(page, user, password) {
    // Same returning-admin seeding as the wizard suite: the shell escalates
    // with the login password, which is how `luke undo` (superuser) runs.
    await page.evaluate((u) => {
        window.localStorage.setItem("superuser:" + u, "sudo");
    }, user);
    await page.fill("#login-user-input", user);
    await page.fill("#login-password-input", password);
    await page.click("#login-button");
}

// Press and hold the undo control for `ms`, then release, without moving the
// pointer (a move would fire pointerleave and cancel the hold). boundingBox
// on a frameLocator returns main-frame coordinates, which is exactly what
// page.mouse speaks.
async function holdUndo(page, ms) {
    const undo = wizard(page).locator("#undo");
    const box = await undo.boundingBox();
    const x = box.x + box.width / 2;
    const y = box.y + box.height / 2;
    await page.mouse.move(x, y);
    await page.mouse.down();
    await page.waitForTimeout(ms);
    await page.mouse.up();
}

test("the armed undo, held by a real finger", async ({ page }) => {
    test.skip(!TOKEN, "LUKE_TOKEN must carry the owner's password");
    test.skip(!ARMED, "LUKE_UNDO_ARMED is set only after the harness stages+applies an update");

    await test.step("sign in as the owner; the landing page is the dashboard", async () => {
        await page.goto("/");
        await login(page, OWNER, TOKEN);
        await expect(wizard(page).locator("#view-done")).toBeVisible({ timeout: 120000 });
    });

    await test.step("the verdict and the journal caught up to the update", async () => {
        // No longer the fresh machine the wizard left: an update was applied,
        // so the verdict is calm and the journal remembers it staging.
        await expect(wizard(page).locator("#verdict-word")).toContainText(
            "Everything is fine.", { timeout: 60000 });
        await expect(wizard(page).locator("#timeline")).toContainText("Staged update v2");
    });

    await test.step("undo is armed now — there is a version to go back to", async () => {
        const undo = wizard(page).locator("#undo");
        await expect(undo).toBeEnabled({ timeout: 60000 });
        await expect(undo).toContainText("Return to v1");
        await expect(wizard(page).locator("#undo-hint")).toContainText("Hold to run");
        await page.screenshot({ path: `${SCREENS}/09-undo-armed.png`, fullPage: true });
    });

    await test.step("letting go early does nothing (you can always let go)", async () => {
        await holdUndo(page, 300);   // well short of the 900ms hold
        // Unchanged: still armed, still offering the same return, no verb ran.
        await expect(wizard(page).locator("#undo")).toContainText("Return to v1");
        await expect(wizard(page).locator("#undo")).toBeEnabled();
    });

    await test.step("holding it to completion runs the undo for real", async () => {
        await holdUndo(page, 1200);   // past the 900ms hold
        // The button confirms the machine's answer, and the journal records
        // the return — the same event the harness will see when it reboots.
        await expect(wizard(page).locator("#undo")).toContainText(
            /Returned\. .* boots next\./, { timeout: 60000 });
        await expect(wizard(page).locator("#timeline")).toContainText(
            "Returned to v1", { timeout: 60000 });
        await page.screenshot({ path: `${SCREENS}/10-undo-done.png`, fullPage: true });
    });
});
