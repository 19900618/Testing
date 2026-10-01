<!-- BEGIN:nextjs-agent-rules -->
# This is NOT the Next.js you know

This version has breaking changes — APIs, conventions, and file structure may all differ from your training data. Read the relevant guide in `node_modules/next/dist/docs/` before writing any code. Heed deprecation notices.
<!-- END:nextjs-agent-rules -->

## Git workflow

- Never commit to `main`. Pull first (`git checkout main && git pull`), then start every piece of work on its own branch: `git checkout -b <short-name>`.
- Commit as the shared EarthEnable identity. Set this once, inside this repo:
  `git config user.name "EarthEnable BI"` and `git config user.email eesystems@earthenable.org`.
  Vercel only builds commits whose author is linked to the Vercel team. Any other author's deployment is BLOCKED (`TEAM_ACCESS_REQUIRED`).
- Test on your own machine with `npm run dev`. Preview deployments carry no data credentials (the env vars are Production-only), so they cannot be used to check a change.
- Run `npm run build` before every push. It includes the type check and is the same build Vercel runs, so failures show up on your machine instead of on the live site.
- Merge on your machine, then push: `git checkout main && git pull && git merge --no-ff <branch> && npm run build && git push`. Avoid GitHub's merge button: it credits the merge to whoever clicks it, which Vercel may block.
- Pushing to `main` deploys production for the whole company. Never use `vercel deploy` from a laptop, or production stops matching GitHub.
