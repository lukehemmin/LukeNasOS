// The dashboard is live, not a snapshot.
//
// The health strip has always polled, but until now the verdict sentence, the
// timeline, and the storage bar rendered once at load. A recovery-first
// dashboard whose whole job is to show what is happening cannot be a
// photograph. This proves the landing refreshes itself: with the machine in
// the RECOVERED state the earlier suite left, it acknowledges the recovery
// through the page's own privileged channel — the same luke verb a future
// "acknowledge" button would call — and then, WITHOUT any page reload, the
// verdict flips from "Recovered itself" to "Everything is fine" on the next
// poll. No page.reload() appears anywhere below on purpose: the change is the
// proof the poll re-fetched and re-rendered on its own.
//
// Runs after landing-responsive so that suite still sees RECOVERED. Guarded on
// LUKE_LIVE so a bare `playwright test` skips it. Terminal: it leaves the
// machine acknowledged (OK), a fine state to end on.
"use strict";

const { test, expect } = require("@playwright/test");

const TOKEN = process.env.LUKE_TOKEN;
const OWNER = process.env.LUKE_OWNER || "sangho";
const LIVE = process.env.LUKE_LIVE;

const SCREENS = "screens";

function wizard(page) {
    return page.frameLocator('iframe[name$="lukenasos-setup"]');
}

function pluginFrame(page) {
    return page.frames().find(
        (f) => /lukenasos-setup/.test(f.name()) || /lukenasos-setup/.test(f.url()));
}

async function landAsOwner(page) {
    await page.goto("/");
    await page.evaluate((u) => {
        window.localStorage.setItem("superuser:" + u, "sudo");
    }, OWNER);
    await page.fill("#login-user-input", OWNER);
    await page.fill("#login-password-input", TOKEN);
    await page.click("#login-button");
    await expect(wizard(page).locator("#view-done")).toBeVisible({ timeout: 120000 });
}

test("the dashboard refreshes itself, with no reload", async ({ page }) => {
    test.skip(!TOKEN, "LUKE_TOKEN must carry the owner's password");
    test.skip(!LIVE, "LUKE_LIVE is set only after the harness leaves the machine RECOVERED");

    await test.step("land on the recovered dashboard", async () => {
        await landAsOwner(page);
        await expect(wizard(page).locator("#verdict-word")).toContainText(
            "Recovered itself. Nothing was lost.", { timeout: 60000 });
    });

    await test.step("acknowledge the recovery through the page's own channel", async () => {
        // Not a reload, not the harness over ssh: the plugin's own cockpit
        // session runs the verb, exactly as a UI "acknowledge" control would.
        // luke status --ack clears the RECOVERED flag; the banner and status
        // return to OK, and the history stays in the journal below.
        const frame = pluginFrame(page);
        expect(frame, "the plugin iframe must be present").toBeTruthy();
        await frame.evaluate(() => new Promise((resolve, reject) => {
            window.cockpit.spawn(["luke", "status", "--ack"], { superuser: "require" })
                .then(resolve, reject);
        }));
    });

    await test.step("the verdict flips to OK on its own, without a reload", async () => {
        // The 15s poll is what carries this: no navigation happens in the
        // test, so a changed verdict can only mean the page re-fetched itself.
        await expect(wizard(page).locator("#verdict-word")).toContainText(
            "Everything is fine.", { timeout: 45000 });
        await expect(wizard(page).locator("#seg-verdict")).toContainText("OK");
        // The journal keeps the history the ack only quieted, not erased.
        await expect(wizard(page).locator("#timeline")).toContainText(
            "Rolled back automatically");
        await page.screenshot({ path: `${SCREENS}/14-live-refreshed.png`, fullPage: true });
    });
});
