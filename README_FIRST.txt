IVs EXCHANGE Logs v25 upgrade package

Start with UPGRADE_V25_SETUP.md. This package upgrades the supplied v24 project and does not deploy itself.

Main files:
- index.html: refreshed mobile drawer, persistent dark-mode toggle, product brand marks, and Paga Checkout parameter update
- upgrade_multi_supplier.sql: additive database migration for two suppliers
- functions/supplier-sync/index.ts: syncs Lucy Lynx and Bestloghub catalogues
- functions/buy/index.ts: routes purchases to the product's supplier

Keep the existing logo/media files and all existing Supabase setup SQL/functions. Back up the live project before deploying. Do not share API keys or secret keys in chat.
