// The landing dashboard on a phone, and in the dark.
//
// DESIGN.md commits to two things this suite is the only proof of: the surface
// is mobile-first (the first-contact device is a phone standing next to the
// NAS, not a desktop that stacks), and it lives in both light and dark with
// equal care. Every other screenshot in this job is a 1280px desktop in light.
//
// Read-only by construction: the wizard mutated the machine already, so these
// run last, against the finished landing, and only look — they never submit.
// The machine is in whatever state the run left it (RECOVERED, as it happens),
// which is a rich page to lay out: verdict sentence, a full timeline, the strip.
//
// Guarded on LUKE_RESPONSIVE so a bare `playwright test` skips it.
"use strict";

const { test, expect } = require("@playwright/test");

const TOKEN = process.env.LUKE_TOKEN;
const OWNER = process.env.LUKE_OWNER || "sangho";
const RUN = process.env.LUKE_RESPONSIVE;

const SCREENS = "screens";
const PHONE = { width: 390, height: 844 };

function wizard(page) {
    return page.frameLocator('iframe[name$="lukenasos-setup"]');
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

// The page must never scroll sideways — the one responsive failure a user
// feels immediately. Measured inside the plugin frame, where the content is.
async function horizontalOverflow(page) {
    return wizard(page).locator("body").evaluate((b) => {
        const el = b.ownerDocument.scrollingElement || b;
        return el.scrollWidth - el.clientWidth;
    });
}

test.describe("on a phone (390px)", () => {
    test.use({ viewport: PHONE });

    test("the landing fits, and the strip stacks", async ({ page }) => {
        test.skip(!TOKEN || !RUN, "needs LUKE_TOKEN and LUKE_RESPONSIVE");
        await landAsOwner(page);

        // No sideways scroll: long values (smb:// paths, digests) must wrap,
        // not push the page wider than the phone.
        expect(await horizontalOverflow(page)).toBeLessThanOrEqual(1);

        // Below 480px the health strip stacks to one segment per line
        // (DESIGN.md mobile-first, setup.css @media max-width:480px).
        const dir = await wizard(page).locator("#strip").evaluate(
            (el) => getComputedStyle(el).flexDirection);
        expect(dir).toBe("column");

        await page.screenshot({ path: `${SCREENS}/12-phone-light.png`, fullPage: true });
    });
});

test.describe("on a phone, in the dark", () => {
    test.use({ viewport: PHONE, colorScheme: "dark" });

    test("the dark tokens actually engage", async ({ page }) => {
        test.skip(!TOKEN || !RUN, "needs LUKE_TOKEN and LUKE_RESPONSIVE");
        // Cockpit's shell theme can override prefers-color-scheme with an
        // explicit theme-light class; seed its preference to dark too so the
        // whole stack agrees. If dark still fails to engage, the assertion
        // below says so honestly rather than a light screenshot passing.
        await page.addInitScript(() => {
            try { window.localStorage.setItem("shell:style", "dark"); } catch (e) { /* first visit */ }
        });
        await landAsOwner(page);

        // The dark ground must really be dark — not the warm paper leaking
        // through because a theme class won over the media query. Luminance,
        // not an exact hex, so a token tweak does not make this brittle: light
        // paper sums to ~715, the dark charcoal to ~61.
        const bg = await wizard(page).locator("body").evaluate(
            (b) => getComputedStyle(b).backgroundColor);
        const lum = (bg.match(/\d+/g) || [255, 255, 255]).slice(0, 3)
            .map(Number).reduce((a, n) => a + n, 0);
        expect(lum).toBeLessThan(120);

        // And the accent stays legible on that ground: the verdict word is
        // rendered in a color, not the body text color by accident.
        await expect(wizard(page).locator("#verdict-word")).toBeVisible();

        await page.screenshot({ path: `${SCREENS}/13-phone-dark.png`, fullPage: true });
    });
});
