// Same-origin proxy: the browser only talks to the frontend; the backend lives on the
// air-gapped network (rollingf-net) and is never published to the host.
const BACKEND = process.env.BACKEND_INTERNAL_URL ?? "http://localhost:8000";

export const dynamic = "force-dynamic";

async function proxy(request: Request, context: { params: Promise<{ path: string[] }> }): Promise<Response> {
  const { path } = await context.params;
  const { search } = new URL(request.url);
  const hasBody = request.method !== "GET" && request.method !== "HEAD";
  try {
    const upstream = await fetch(`${BACKEND}/api/v1/${path.map(encodeURIComponent).join("/")}${search}`, {
      method: request.method,
      headers: { "content-type": request.headers.get("content-type") ?? "application/json" },
      body: hasBody ? await request.text() : undefined,
      cache: "no-store",
    });
    return new Response(upstream.body, {
      status: upstream.status,
      headers: { "content-type": upstream.headers.get("content-type") ?? "application/json" },
    });
  } catch {
    // Localized by the UI (the proxy has no language context).
    return Response.json({ code: "backend_unavailable" }, { status: 502 });
  }
}

export { proxy as GET, proxy as POST };
