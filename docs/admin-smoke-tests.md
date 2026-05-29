# Admin Approval And Assignment Smoke Tests

The admin approval/assignment smoke test creates temporary admin, customer, and electrician accounts, approves pending electricians, creates a customer order, assigns an electrician, verifies reassignment rules, and removes the temporary data.

## Local Run

Use the current `.env.local` Supabase credentials:

```sh
npm run smoke:admin-flow:local
```

Production requires an explicit confirmation flag:

```sh
npm run smoke:admin-flow:production
```

## GitHub Actions

Pull requests and pushes to `main` run the smoke against staging when these secrets are configured:

- `STAGING_SUPABASE_URL`
- `STAGING_SUPABASE_ANON_KEY`
- `STAGING_SUPABASE_SERVICE_ROLE_KEY`

Do not point the `STAGING_` secrets at production; leave them unset until a real staging Supabase project exists.

Production smoke is manual only. Run the `Admin Approval Assignment Smoke` workflow with `target = production` after deploying, using:

- `PRODUCTION_SUPABASE_URL`
- `PRODUCTION_SUPABASE_ANON_KEY`
- `PRODUCTION_SUPABASE_SERVICE_ROLE_KEY`

If a target's secrets are missing, the workflow skips that smoke with a warning instead of failing unrelated checks.
