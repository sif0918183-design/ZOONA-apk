# Supabase Deployment Instructions

## 1. SQL Migrations
Apply the migrations to your Supabase project using the Dashboard SQL Editor or the Supabase CLI:

```bash
# Using CLI
supabase db push
```

Or copy the content of `supabase/migrations/20240520_create_get_nearest_drivers.sql` and run it in the Supabase SQL Editor.

## 2. Edge Functions
To deploy the `dispatch-ride` function, follow these steps:

### Prerequisites
- [Supabase CLI](https://supabase.com/docs/guides/cli) installed and logged in.
- Your project initialized with `supabase init`.

### Deployment Commands

1.  **Login to Supabase** (if not already):
    ```bash
    supabase login
    ```

2.  **Link your project**:
    ```bash
    supabase link --project-ref <your-project-id>
    ```

3.  **Deploy the function**:
    ```bash
    # From the pwa_to_flutter_app/supabase directory
    supabase functions deploy dispatch-ride --no-verify-jwt
    ```

4.  **Set Environment Variables**:
    Ensure the following secrets are set in your Supabase project:
    ```bash
    supabase secrets set SUPABASE_URL=...
    supabase secrets set SUPABASE_SERVICE_ROLE_KEY=...
    ```

## 3. Database Schema Assumptions
The `get_nearest_drivers_v2` function assumes the following tables exist:
- `driver_locations`:
    - `driver_id` (UUID)
    - `location` (geography(POINT))
    - `is_online` (BOOLEAN)
    - `last_seen` (TIMESTAMP)
- `drivers`:
    - `id` (UUID)
    - `vehicle_type` (TEXT)
