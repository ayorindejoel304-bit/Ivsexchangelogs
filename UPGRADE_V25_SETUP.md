# IVs EXCHANGE Logs v25 — Interface, theme, product marks, and two suppliers

This package updates the existing v24 project; it is not a fresh rebuild.

## Included

- Persistent light/dark mode toggle.
- Refined mobile drawer based on the supplied Bestloghub dashboard reference: welcome/status, wallet balance, and Fund Wallet shortcut.
- Product brand marks on supplier-market cards (Facebook, Instagram, WhatsApp, TikTok, Telegram, X, VPN, TextNow, TextPlus, and a generic digital mark).
- Second supplier support for Bestloghub alongside the existing Lucy Lynx supplier.
- Supplier-specific sync buttons in Admin → Supplier.
- Updated Paga Checkout JS and hosted-link fallback parameters to match Paga's current Checkout documentation.
- Existing WhatsApp floating support button retained; Telegram is not used as the site's support shortcut.

## Deployment sequence

1. Back up the currently deployed website and the current Supabase SQL/functions.
2. In the SAME Supabase project, run `upgrade_multi_supplier.sql` after the existing `wallet_setup.sql` migration. This is additive and keeps the current `supplier_products` rows as Lucy Lynx products.
3. In Supabase → Edge Functions → Secrets, add:
   - `BESTLOGHUB_API_KEY` = the API key from the Bestloghub developer dashboard
   - `BESTLOGHUB_API_URL` = `https://bestloghub.site/api/v1` (optional; this is the default)
   Keep the existing `SUPPLIER_API_KEY`, `SUPPLIER_API_URL`, Paga secrets, and Supabase secrets unchanged.
4. Replace the code for the existing Edge Function `supplier-sync` with `functions/supplier-sync/index.ts`.
5. Replace the code for the existing Edge Function `buy` with `functions/buy/index.ts`.
6. Keep the existing Paga Edge Functions (`paga-init`, `paga-callback`, `paga-verify`) and their secrets. The updated website still calls those functions.
7. Upload the updated `index.html` to the root of the existing Vercel project and redeploy. Keep the existing logo and other static assets in place.
8. Log in as admin → Supplier. First test **Sync Supplier 1**, then **Sync Bestloghub**. Check the supplier label, product names, prices, and stock before enabling sales.

## Bestloghub API assumptions to verify before live sales

The supplied API guide confirms Bearer-token authentication and these routes:

- `GET /api/v1/products`
- `GET /api/v1/categories`
- `GET /api/v1/me`
- `POST /api/v1/purchase` with `{ "product_id": 1, "quantity": 1 }`
- `GET /api/v1/orders`
- `GET /api/v1/orders/{id}`
- `GET /api/v1/orders/{id}/credentials`

The integration expects the product-list response to include numeric `id`, product name, `price`, and stock/availability fields (or equivalent `product_id`, `title`, `amount`, `quantity` fields). Product IDs are namespaced internally to avoid collisions with Lucy Lynx IDs. The purchase handler attempts to read credentials from the purchase response, then calls the documented order-credentials endpoint when needed.

Before accepting real customer orders from Bestloghub, test one low-value order with supplier support / a controlled test account and confirm the exact response fields and credential delivery format. The guide screenshots supplied did not show full response examples for products, purchase, or credentials. If the supplier's JSON differs, adjust the response mapping in `supplier-sync` or `buy` before going live.

## Paga checkout note

The checkout launch now follows Paga's documented JavaScript Checkout and hosted payment-link parameter names, sends a two-decimal NGN amount, and explicitly lists supported funding methods. Payment is still credited only after the existing server-side callback hash verification or Verify Charge check.

The screenshot error **“Failed to get fee details”** is returned by Paga's hosted checkout. A code change cannot confirm or repair a merchant-side fee profile, account configuration, or Paga service issue. Test with the live account after redeploying. If the same error persists, share the payment reference and timestamp with Paga merchant support and ask them to check fee calculation for the merchant public key. Do not send secret/hash keys to support chat or put them in the frontend.

## Security

- Never put supplier API keys, Paga secret keys, Paga hash keys, or the Supabase service-role key in `index.html`.
- Do not send API keys in this chat. Add them only to Supabase Edge Function Secrets.
- Do not switch to real customer sales until the second supplier's purchase response and credential delivery have been verified.
- The supplier call can time out after the provider has accepted an order. Such orders remain Processing for admin review; do not blindly refund until checking supplier order history.

## Rollback

Restore the backed-up v24 `index.html`, `buy` and `supplier-sync` function code if needed. The SQL migration is additive; it does not delete existing Lucy Lynx products or wallet/order records.
