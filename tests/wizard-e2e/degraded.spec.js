// The degraded dashboard — the third verdict, the one that says "act".
//
// OK and RECOVERED have both rendered on real machines now. DEGRADED never
// has: it is the state where a required health check is failing RIGHT NOW (not
// a past rollback), and the machine needs the owner to do something. The
// harness has failed a required check on the running machine — no reboot, so
// no rollback: the box stays up and reachable, but luke's verdict turns
// ✕ DEGRADED. This proves the dashboard renders that state as a sentence and
// points at the fix, completing the verdict trilogy on a real machine.
//
// Guarded on LUKE_DEGRADED. Terminal: the harness removes the failing check
// after, but this is the last browser step before the VM is torn down anyway.
"use strict";

const { test, expect } = require("@playwright/test");

const TOKEN = process.env.LUKE_TOKEN;
const OWNER = process.env.LUKE_OWNER || "sangho";
const DEGRADED = process.env.LUKE_DEGRADED;

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

test("the degraded dashboard, when a required check is failing now", async ({ page }) => {
    test.skip(!TOKEN, "LUKE_TOKEN must carry the owner's password");
    test.skip(!DEGRADED, "LUKE_DEGRADED is set only after the harness fails a required check");

    await test.step("sign in as the owner; the landing page is the dashboard", async () => {
        await page.goto("/");
        await login(page, OWNER, TOKEN);
        await expect(wizard(page).locator("#view-done")).toBeVisible({ timeout: 120000 });
    });

    await test.step("the verdict says something needs attention, and where to act", async () => {
        await expect(wizard(page).locator("#verdict-word")).toContainText(
            "Something needs attention.", { timeout: 60000 });
        const plain = wizard(page).locator("#verdict-plain");
        await expect(plain).toContainText("data is still served");
        await expect(plain).toContainText("luke doctor");
    });

    await test.step("the health strip shows the degraded segment", async () => {
        await expect(wizard(page).locator("#seg-verdict")).toContainText(
            "degraded", { timeout: 60000 });
        await page.screenshot({ path: `${SCREENS}/15-degraded.png`, fullPage: true });
    });
});
