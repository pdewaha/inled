Deno.serve(async () => {
  return new Response(JSON.stringify("Hello from Edge Functions!"), {
    headers: { "Content-Type": "application/json" },
  });
});
