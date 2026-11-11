# Wallet and supplier setup

For the v24 base installation steps, see the original deployment instructions in the earlier project backup. For the v25 two-supplier upgrade, follow `UPGRADE_V25_SETUP.md`.

Existing Supabase secrets and Edge Functions should be retained. The v25 package adds `BESTLOGHUB_API_KEY` and updates only the `buy` and `supplier-sync` Edge Functions. Paga's secret/hash keys remain server-side.
