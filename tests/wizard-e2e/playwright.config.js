// Playwright config for the wizard's browser E2E.
//
// One worker, no retries, generous timeouts: the machine under test is a
// TCG-emulated VM in CI, and the wizard's step 3 legitimately takes minutes
// (the first share pulls the Samba image). A retry would not be a retry —
// the wizard mutates the machine, so the second attempt would meet a
// different machine.
"use strict";

const { defineConfig } = require("@playwright/test");

module.exports = defineConfig({
    testDir: ".",
    timeout: 20 * 60 * 1000,
    retries: 0,
    workers: 1,
    fullyParallel: false,
    use: {
        baseURL: process.env.COCKPIT_URL || "https://localhost:9990",
        // The device has no public domain; the self-signed warning is part
        // of the product's own first-contact story (the banner promises it).
        ignoreHTTPSErrors: true,
        viewport: { width: 1280, height: 800 },
        screenshot: "only-on-failure",
        trace: "retain-on-failure",
    },
    reporter: [["list"]],
});
