// The recovered dashboard — the product's whole reason for existing, on screen.
//
// "A NAS with an undo button" earns its tagline when an update goes bad and
// the machine puts itself back without anyone awake for it. Every other
// screenshot in this suite shows the calm case ("Everything is fine."). This
// one is the headline: the harness has pointed the box at the deliberately
// broken image and let greenboot roll it back hands-off, so the dashboard is
// now rendering the RECOVERED verdict for the first time on a real machine.
//
// It proves the three things that only ever run in this state:
//   1. The verdict speaks the recovery as a sentence, and names the version
//      the machine is safely back on.
//   2. The journal records the automatic rollback.
//   3. The undo control does NOT offer to return to the version that just
//      failed here — the rollback slot holds the broken build, and re-arming
//      undo would undo the recovery itself (rollback_blocked).
//
// Guarded on LUKE_RECOVERED_SHOWN so a bare `playwright test` skips it.
"use strict";

const { test, expect } = require("@playwright/test");

const TOKEN = process.env.LUKE_TOKEN;
const OWNER = process.env.LUKE_OWNER || "sangho";
const SHOWN = process.env.LUKE_RECOVERED_SHOWN;

const SCREENS = "screens";

function wizard(page) {
    return page.frameLocator('iframe[name$="lukenasos-setup"]');
}

async function login(page, user, password) {
    await page.evaluate((u) => {
        window.localStorage.setItem("superuser:" + u, "sudo");
    }, user);
    await page.fill("#login-user-input", user);
    await page.fill("#login-password-input", password);
    await page.click("#login-button");
}

test("the recovered dashboard, on a machine that rolled itself back", async ({ page }) => {
    test.skip(!TOKEN, "LUKE_TOKEN must carry the owner's password");
    test.skip(!SHOWN, "LUKE_RECOVERED_SHOWN is set only after the harness forces an auto-rollback");

    await test.step("sign in as the owner; the landing page is the dashboard", async () => {
        await page.goto("/");
        await login(page, OWNER, TOKEN);
        await expect(wizard(page).locator("#view-done")).toBeVisible({ timeout: 120000 });
    });

    await test.step("the verdict speaks the recovery, and names the safe version", async () => {
        await expect(wizard(page).locator("#verdict-word")).toContainText(
            "Recovered itself. Nothing was lost.", { timeout: 60000 });
        const plain = wizard(page).locator("#verdict-plain");
        await expect(plain).toContainText("rolled back");
        await expect(plain).toContainText("running v1");
        await expect(plain).toContainText("data volume was never touched");
    });

    await test.step("the health strip shows the recovered segment", async () => {
        await expect(wizard(page).locator("#seg-verdict")).toContainText(
            "recovered", { timeout: 60000 });
    });

    await test.step("the journal records the automatic rollback", async () => {
        await expect(wizard(page).locator("#timeline")).toContainText(
            "Rolled back automatically");
    });

    await test.step("undo does NOT offer to return to the version that just failed", async () => {
        // The rollback slot holds the broken build (rollback_blocked). A live
        // "Return to v2-broken" button would let the user undo the recovery;
        // the control stays down and says why.
        await expect(wizard(page).locator("#undo")).toBeDisabled();
        await expect(wizard(page).locator("#undo-hint")).toContainText("set aside");
        await page.screenshot({ path: `${SCREENS}/11-recovered.png`, fullPage: true });
    });
});
