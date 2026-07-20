// The degraded dashboard — the third verdict, the one that says "act".
//
// OK and RECOVERED have both rendered on real machines; DEGRADED could not,
// because current_verdict read it only from greenboot-healthcheck, which runs
// once at boot and refuses a manual re-run. The live health re-check
// (lukenasos-health.timer) fixed that: a fault that develops AFTER boot now
// turns the verdict ✕ DEGRADED. So the harness kills the share's file server
// on the running machine — a realistic post-boot degradation, the OS fine but
// the NAS no longer serving — and this proves the dashboard says so, names the
// cause, and points at the fix. That completes the verdict trilogy on a real
// machine AND proves the reachability fix.
//
// Guarded on LUKE_DEGRADED. Terminal: the harness restarts samba after.
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

test("the degraded dashboard, when the file server has died post-boot", async ({ page }) => {
    test.skip(!TOKEN, "LUKE_TOKEN must carry the owner's password");
    test.skip(!DEGRADED, "LUKE_DEGRADED is set only after the harness kills samba + re-checks");

    await test.step("sign in as the owner; the landing page is the dashboard", async () => {
        await page.goto("/");
        await login(page, OWNER, TOKEN);
        await expect(wizard(page).locator("#view-done")).toBeVisible({ timeout: 120000 });
    });

    await test.step("the verdict says something needs attention, and NAMES the fault", async () => {
        await expect(wizard(page).locator("#verdict-word")).toContainText(
            "Something needs attention.", { timeout: 60000 });
        const plain = wizard(page).locator("#verdict-plain");
        // The live re-check named the cause — the dashboard shows it instead of
        // a generic "your data is still served" that would be a lie here.
        await expect(plain).toContainText(/samba|file sharing/i);
        await expect(plain).toContainText("luke doctor");
    });

    await test.step("the health strip shows the degraded segment", async () => {
        await expect(wizard(page).locator("#seg-verdict")).toContainText(
            "degraded", { timeout: 60000 });
        await page.screenshot({ path: `${SCREENS}/15-degraded.png`, fullPage: true });
    });
});
