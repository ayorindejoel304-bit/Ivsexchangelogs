// Edge Function: supplier-sync (ADMIN ONLY)
// Supports the existing Lucy Lynx supplier and Bestloghub as a second supplier.
// Secrets: SUPPLIER_API_KEY, BESTLOGHUB_API_KEY; optional *_API_URL values.
import { createClient } from "npm:@supabase/supabase-js@2";

const cors = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type" };
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...cors, "Content-Type": "application/json" } });
const unwrap = (d: any): any[] => Array.isArray(d) ? d : Array.isArray(d?.results) ? d.results : Array.isArray(d?.data) ? d.data : Array.isArray(d?.products) ? d.products : [];
const logoFor = (s: string) => {
  const x = s.toLowerCase();
  if (/facebook|\bfb\b/.test(x)) return "facebook";
  if (/instagram|\big\b/.test(x)) return "instagram";
  if (/whatsapp/.test(x)) return "whatsapp";
  if (/tiktok/.test(x)) return "tiktok";
  if (/telegram/.test(x)) return "telegram";
  if (/twitter|\bx\b/.test(x)) return "x";
  if (/vpn/.test(x)) return "vpn";
  if (/textnow/.test(x)) return "textnow";
  if (/textplus/.test(x)) return "textplus";
  return "digital";
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
    const jwt = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
    const { data: u } = await db.auth.getUser(jwt);
    const email = u?.user?.email?.toLowerCase();
    if (!email) return json({ error: "Please log in again." }, 401);
    const { data: adm } = await db.from("admin_emails").select("email").ilike("email", email).maybeSingle();
    if (!adm) return json({ error: "Admins only." }, 403);

    const { action = "sync" } = await req.json().catch(() => ({}));
    const syncLucy = action === "sync" || action === "sync-lucy";
    const syncBest = action === "sync" || action === "sync-bestloghub";
    const totals: Record<string, number> = {};

    if (syncLucy) {
      const key = Deno.env.get("SUPPLIER_API_KEY");
      const base = (Deno.env.get("SUPPLIER_API_URL") || "https://lucylynxsocials.com/api/v1").replace(/\/$/, "");
      if (!key) return json({ error: "SUPPLIER_API_KEY secret is not set." }, 500);
      const api = async (path: string) => {
        const r = await fetch(base + path, { headers: { Authorization: "Bearer " + key } });
        const d = await r.json().catch(() => ({}));
        if (!r.ok) throw new Error(`Lucy Lynx ${r.status}: ${d.error || d.detail || "request failed"}`);
        return d;
      };
      const cats = unwrap(await api("/categories"));
      const catName: Record<string, string> = {};
      for (const c of cats) catName[String(c.id)] = String(c.name || "Other");
      const all: any[] = [];
      for (let page = 1; page <= 100; page++) {
        const d = await api(`/products?page=${page}`), rows = unwrap(d);
        if (!rows.length) break;
        all.push(...rows);
        if ((d.count && all.length >= d.count) || d.next === null) break;
      }
      const rows = all.map((p: any) => ({
        id: Number(p.id), supplier_key: "lucylynxsocials", supplier_product_id: String(p.id),
        category_id: p.category_id == null ? null : Number(p.category_id),
        category_name: catName[String(p.category_id)] || String(p.category || "Other"),
        name: String(p.name || p.title || `Product ${p.id}`), supplier_price: Number(p.price) || 0,
        stock: Number(p.stock) || 0, in_stock: p.in_stock !== false && (Number(p.stock) || 0) > 0,
        logo_key: logoFor(String(p.name || p.category || "")), updated_at: new Date().toISOString()
      }));
      if (!rows.length) throw new Error("Lucy Lynx returned no products.");
      for (let i = 0; i < rows.length; i += 500) {
        const { error } = await db.from("supplier_products").upsert(rows.slice(i, i + 500), { onConflict: "id" });
        if (error) throw new Error(error.message);
      }
      const ids = rows.map((r: any) => r.id).join(",");
      await db.from("supplier_products").update({ in_stock: false, stock: 0 }).eq("supplier_key", "lucylynxsocials").not("id", "in", `(${ids})`);
      totals.lucy_products = rows.length; totals.lucy_categories = cats.length;
    }

    if (syncBest) {
      const key = Deno.env.get("BESTLOGHUB_API_KEY");
      const base = (Deno.env.get("BESTLOGHUB_API_URL") || "https://bestloghub.site/api/v1").replace(/\/$/, "");
      if (!key) return json({ error: "BESTLOGHUB_API_KEY secret is not set." }, 500);
      const api = async (path: string) => {
        const r = await fetch(base + path, { headers: { Authorization: "Bearer " + key, Accept: "application/json" } });
        const d = await r.json().catch(() => ({}));
        if (!r.ok) throw new Error(`Bestloghub ${r.status}: ${d.error || d.detail || d.message || "request failed"}`);
        return d;
      };
      const catsRaw = unwrap(await api("/categories"));
      const catName: Record<string, string> = {};
      catsRaw.forEach((c: any) => catName[String(c.id)] = String(c.name || c.title || "Other"));
      const all: any[] = [];
      for (let page = 1; page <= 100; page++) {
        const d = await api(`/products?page=${page}`), rows = unwrap(d);
        if (!rows.length) break;
        all.push(...rows);
        if ((d.count && all.length >= Number(d.count)) || d.next === null) break;
      }
      const rows = all.map((p: any) => {
        const sourceId = String(p.id ?? p.product_id ?? "");
        const numericId = Number(sourceId);
        if (!sourceId || !Number.isSafeInteger(numericId) || numericId < 0 || numericId >= 1000000000000) return null;
        const title = String(p.name || p.title || p.product_name || `Product ${sourceId}`);
        const categoryId = p.category_id ?? p.category?.id ?? null;
        const stock = Number(p.stock ?? p.quantity ?? (p.in_stock === true ? 1 : 0)) || 0;
        return {
          id: 2000000000000 + numericId, supplier_key: "bestloghub", supplier_product_id: sourceId,
          category_id: categoryId == null ? null : Number(categoryId),
          category_name: catName[String(categoryId)] || String(p.category_name || p.category?.name || p.category || "Other"),
          name: title, supplier_price: Number(p.price ?? p.amount ?? 0) || 0,
          stock, in_stock: p.in_stock === false ? false : stock > 0,
          logo_key: logoFor(`${title} ${p.category_name || ""}`), updated_at: new Date().toISOString()
        };
      }).filter(Boolean);
      if (!rows.length) throw new Error("Bestloghub returned no usable products. Confirm its product list response fields in the API documentation.");
      for (let i = 0; i < rows.length; i += 500) {
        const { error } = await db.from("supplier_products").upsert(rows.slice(i, i + 500), { onConflict: "id" });
        if (error) throw new Error(error.message);
      }
      const ids = rows.map((r: any) => r.id).join(",");
      await db.from("supplier_products").update({ in_stock: false, stock: 0 }).eq("supplier_key", "bestloghub").not("id", "in", `(${ids})`);
      totals.bestloghub_products = rows.length; totals.bestloghub_categories = catsRaw.length;
    }

    if (action === "balance" || action === "balance-lucy") {
      const key = Deno.env.get("SUPPLIER_API_KEY");
      const base = (Deno.env.get("SUPPLIER_API_URL") || "https://lucylynxsocials.com/api/v1").replace(/\/$/, "");
      if (!key) return json({ error: "SUPPLIER_API_KEY secret is not set." }, 500);
      const r = await fetch(base + "/balance", { headers: { Authorization: "Bearer " + key } });
      const d = await r.json().catch(() => ({}));
      if (!r.ok) return json({ error: `Lucy Lynx ${r.status}` }, 502);
      return json(d);
    }
    return json({ ok: true, ...totals, products: (totals.lucy_products || 0) + (totals.bestloghub_products || 0) });
  } catch (e) { console.error(e); return json({ error: String((e as Error).message || e) }, 500); }
});
