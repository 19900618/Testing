# Setup checklist

These are the steps that need a human clicking in Google Cloud / GitHub / Vercel.
Everything else (the app itself) is already built. **You only need Step 1 to see
live data locally.** Steps 2–4 come later, when we add login and deploy.

---

## 1. BigQuery service account  ← do this now

This gives the app read-only access to BigQuery.

1. Go to **console.cloud.google.com** → make sure the project is **earth-enable-main** (top bar).
2. Menu → **IAM & Admin → Service Accounts** → **Create service account**.
   - Name: `bi-dashboard-reader`
   - Click **Create and continue**.
3. Grant it **two roles** (add role, repeat):
   - **BigQuery Data Viewer**
   - **BigQuery Job User**
   - Click **Done**.
4. Click the new account → **Keys** tab → **Add key → Create new key → JSON** → **Create**.
   A `.json` file downloads.
5. Rename that file to **`gcp-key.json`** and put it in this folder:
   `C:\Users\sw\Desktop\EarthEnable\0. AI Models\BI Project\dashboard\gcp-key.json`
6. Back in the terminal, restart the app (`Ctrl+C`, then `npm run dev`) and refresh
   **http://localhost:3000**. You should see real data.

> `gcp-key.json` is git-ignored — it will never be committed or leave your machine.

---

## 2. Google OAuth client  (later — for login)

So only `@earthenable.org` accounts can open the app.

1. Cloud Console → **APIs & Services → Credentials** → **Create credentials → OAuth client ID**.
2. Application type: **Web application**.
3. **Authorized JavaScript origins:** `http://localhost:3000` (and later your Vercel URL).
4. **Authorized redirect URIs:**
   - `http://localhost:3000/api/auth/callback/google`
   - (later) `https://YOUR-APP.vercel.app/api/auth/callback/google`
5. Copy the **Client ID** and **Client secret** into `.env.local`
   (`GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`).

---

## 3. GitHub repo  (later — for deploy)

`gh` isn't installed, so create it in the browser:

1. **github.com/new** → name e.g. `earthenable-bi` → **Private** → Create (no README).
2. Tell me the repo URL and I'll commit and push this project to it.

---

## 4. Vercel  (later — the live link)

1. **vercel.com** → sign in with **GitHub** → **Add New → Project** → import `earthenable-bi`.
2. **Root Directory:** set to `dashboard` (this app lives in a subfolder).
3. **Environment Variables** — add:
   - `GCP_SERVICE_ACCOUNT_KEY` = the full contents of `gcp-key.json` (paste as one value)
   - `GCP_PROJECT_ID` = `earth-enable-main`
   - `NEXTAUTH_SECRET`, `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`, `NEXTAUTH_URL`, `ALLOWED_EMAIL_DOMAIN`
4. **Deploy.** You get a live URL. Add that URL back into the OAuth client (Step 2.4).
