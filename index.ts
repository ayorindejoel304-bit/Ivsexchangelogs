// Edge Function: buy. Routes wallet purchases to the supplier attached to each product.
// Secrets: SUPPLIER_API_KEY, BESTLOGHUB_API_KEY; supplier credentials never reach the browser.
import { createClient } from "npm:@supabase/supabase-js@2";
const cors = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type" };
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...cors, "Content-Type": "application/json" } });
const FRIENDLY: Record<string, [string, number]> = {
  insufficient_balance: ["Your wallet balance is too low. Please add funds.", 402], out_of_stock: ["This product is out of stock or has fewer items than you asked for.", 409], product_not_found: ["Product not found.", 404], bad_quantity: ["Choose a quantity between 1 and 100.", 400]
};
Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
    const jwt = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
    const { data: u } = await db.auth.getUser(jwt);
    if (!u?.user) return json({ error: "Please log in again." }, 401);
    const body = await req.json().catch(() => ({}));
    const product = Number(body.product), quantity = Math.floor(Number(body.quantity) || 1);
    if (!Number.isSafeInteger(product) || product < 1) return json({ error: "Invalid product." }, 400);
    const { data: p, error: pe } = await db.from("supplier_products").select("id,supplier_key,supplier_product_id,name").eq("id", product).eq("active", true).maybeSingle();
    if (pe || !p) return json({ error: "Product not found." }, 404);
    const { data: r, error: re } = await db.rpc("svc_reserve", { p_user: u.user.id, p_product: product, p_qty: quantity });
    if (re) {
      const hit = Object.keys(FRIENDLY).find((k) => re.message.includes(k));
      if (hit) return json({ error: FRIENDLY[hit][0] }, FRIENDLY[hit][1]);
      console.error("reserve failed", re.message); return json({ error: "Could not start your order. Try again." }, 500);
    }
    const orderId: number = r.order_id;
    const provider = String(p.supplier_key || "lucylynxsocials");
    const key = provider === "bestloghub" ? Deno.env.get("BESTLOGHUB_API_KEY") : Deno.env.get("SUPPLIER_API_KEY");
    const base = (provider === "bestloghub"
      ? Deno.env.get("BESTLOGHUB_API_URL") || "https://bestloghub.site/api/v1"
      : Deno.env.get("SUPPLIER_API_URL") || "https://lucylynxsocials.com/api/v1").replace(/\/$/, "");
    if (!key) { await db.rpc("svc_fail", { p_order: orderId, p_error: `${provider} API key is not configured` }); return json({ error: "This supplier is not configured. Your wallet was refunded." }, 503); }

    const ctl = new AbortController(), timer = setTimeout(() => ctl.abort(), 25000);
    let res: Response;
    try {
      const isBest = provider === "bestloghub";
      res = await fetch(base + (isBest ? "/purchase" : "/buy"), {
        method: "POST", headers: { Authorization: "Bearer " + key, "Content-Type": "application/json", Accept: "application/json" },
        body: JSON.stringify(isBest ? { product_id: Number(p.supplier_product_id), quantity } : { product: Number(p.supplier_product_id || p.id), quantity }), signal: ctl.signal
      });
    } catch (_e) {
      return json({ pending: true, order_id: orderId, error: "Your order is being processed. Check My Orders shortly." }, 202);
    } finally { clearTimeout(timer); }
    let data: any = await res.json().catch(() => ({}));
    if (res.ok) {
      const orderRef = String(data.order_id ?? data.id ?? data.order?.id ?? data.data?.order_id ?? data.data?.id ?? "");
      let keys = Array.isArray(data.keys) ? data.keys : Array.isArray(data.credentials) ? data.credentials : Array.isArray(data.data?.keys) ? data.data.keys : [];
      if (provider === "bestloghub" && !keys.length && orderRef) {
        const detail = await fetch(base + `/orders/${encodeURIComponent(orderRef)}/credentials`, { headers: { Authorization: "Bearer " + key, Accept: "application/json" } });
        const cred = await detail.json().catch(() => ({}));
        if (detail.ok) keys = Array.isArray(cred) ? cred : Array.isArray(cred.credentials) ? cred.credentials : Array.isArray(cred.keys) ? cred.keys : Array.isArray(cred.data) ? cred.data : [];
      }
      const normalizedKeys = keys.map((x: any) => typeof x === "string" ? x : JSON.stringify(x));
      const fin = await db.rpc("svc_finalize", { p_order: orderId, p_keys: normalizedKeys, p_supplier_order: orderRef, p_supplier_charge: Number(data.charge ?? data.amount ?? data.total) || null });
      if (fin.error) console.error("FINALIZE FAILED", orderId, fin.error.message);
      return json({ order_id: orderId, keys: normalizedKeys, charge: r.charge });
    }
    if ([400, 401, 402, 404, 409, 422, 429].includes(res.status)) {
      await db.rpc("svc_fail", { p_order: orderId, p_error: `${provider} ${res.status}: ${data.error || data.message || ""}` });
      if (res.status === 409) return json({ error: "Not enough stock for that quantity. You were not charged." }, 409);
      if (res.status === 429) return json({ error: "Too many requests. Please wait a moment. You were not charged." }, 429);
      return json({ error: "This product is temporarily unavailable. Your wallet was refunded." }, 502);
    }
    console.error("supplier outcome unclear", provider, res.status, JSON.stringify(data));
    return json({ pending: true, order_id: orderId, error: "Your order is being processed. Check My Orders shortly." }, 202);
  } catch (e) { console.error(e); return json({ error: "Something went wrong. Please try again." }, 500); }
});
