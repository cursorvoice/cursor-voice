# Turning on analytics — step by step

The site already has all the tracking code, a consent banner, and a privacy
policy. The only missing piece is **your Google Analytics 4 Measurement ID**.
Here's exactly how to get it and plug it in. ~10 minutes.

---

## Part 1 — Create the GA4 property

1. Go to **https://analytics.google.com** and sign in with your Google account.
2. If it's your first time, click **Start measuring**. Otherwise: bottom-left
   gear icon (**Admin**) → **Create** → **Property**.
3. **Property name:** `Cursor Voice` → set your time zone and currency → **Next**.
4. Fill the business details (pick anything reasonable — "Technology", smallest
   size) → **Create** → accept the terms.

## Part 2 — Create a Web data stream

1. After the property is made, it asks to **choose a platform** → click **Web**.
   (If you skipped it: **Admin** → **Data streams** → **Add stream** → **Web**.)
2. **Website URL:** `https://tottenabderrahmane1-create.github.io`
   **Stream name:** `cursor-voice site` → **Create stream**.
3. You'll land on the stream details page. At the top you'll see:

   ```
   MEASUREMENT ID    G-XXXXXXXXXX
   ```

   **Copy that `G-...` value.** That's the one thing you need.

## Part 3 — Put the ID in the site

1. Open `docs/index.html` in the repo.
2. Near the top (in the `<head>`), find this line:

   ```js
   window.CV_GA_ID = 'G-XXXXXXXXXX'; // ← your GA4 Measurement ID
   ```

3. Replace `G-XXXXXXXXXX` with your real ID, e.g.:

   ```js
   window.CV_GA_ID = 'G-AB12CD34EF';
   ```

4. Save, then commit and push:

   ```bash
   cd "<your repo path>/cursor-voice"
   git add docs/index.html
   git commit -m "Wire in GA4 Measurement ID"
   git push
   ```

   GitHub Pages rebuilds in ~1 minute.

## Part 4 — Verify it's working

1. Open the live site: **https://tottenabderrahmane1-create.github.io/cursor-voice/**
2. The cookie banner appears → click **Allow analytics**.
3. In Google Analytics, go to **Reports → Realtime** (left sidebar).
   Within ~30 seconds you should see **1 active user** (you).
4. Scroll around, click the install button, copy a command. In Realtime →
   **Event count by Event name**, you'll see your custom events show up:
   `scroll_depth`, `section_view`, `cta_click`, `copy_command`,
   `outbound_click`, `time_engaged`.

That's it — it's live.

---

## What you'll be able to see (after data accumulates)

GA4 gives you out of the box:
- **Realtime** — who's on the site right now.
- **Reports → Engagement → Events** — counts of every custom event above.
- **Reports → Engagement → Pages and screens** — views.
- **Reports → Acquisition** — where traffic comes from (direct, GitHub, search, social).
- **Reports → Tech / Geography** — device, browser, country.

### Recommended: mark key events as "Key events" (conversions)

So you can track them as goals:

1. **Admin → Events** (under Data display) — wait until events have fired at
   least once so they appear in the list.
2. Toggle **Mark as key event** for: `cta_click`, `copy_command`,
   `outbound_click`.

Now GA treats an install-button click or a copied command as a conversion,
and you can see conversion rate over time.

### Optional: custom funnel

**Explore → Funnel exploration**, steps:
`page_view` → `section_view (install)` → `copy_command` → `outbound_click`.
That shows you exactly where people drop off between landing and installing.

---

## Notes

- **Nothing tracks until someone clicks "Allow analytics."** That's by design
  (Google Consent Mode v2, default denied). Returning visitors who already
  chose aren't re-prompted.
- **Before you add the ID**, every event still fires into the browser console
  (`[analytics] …`) so you can watch them work in DevTools, but nothing leaves
  the browser.
- **IP anonymization** is on. The privacy policy at `docs/privacy.html`
  already documents all of this.
- If you ever want to **swap to a cookieless analytics** tool (Plausible,
  Fathom — no banner needed, simpler, ~$9/mo), say the word and it's a small
  change.
