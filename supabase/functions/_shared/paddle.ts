// Shared Paddle API config for the billing functions (create-checkout,
// customer-portal). The environment is baked into the key (`pdl_live_…` vs
// `pdl_sdbx_…`), so the API host follows it automatically — flipping
// sandbox↔live is a single secret swap (PADDLE_API_KEY). PADDLE_API_BASE stays
// as an override.
const PADDLE_API_KEY = Deno.env.get("PADDLE_API_KEY");

export const PADDLE_API_BASE = Deno.env.get("PADDLE_API_BASE")
    ?? (PADDLE_API_KEY?.startsWith("pdl_live_") ? "https://api.paddle.com" : "https://sandbox-api.paddle.com");

export const PADDLE_HEADERS = {
    "Authorization": `Bearer ${PADDLE_API_KEY}`,
    "Content-Type": "application/json",
    "Paddle-Version": "1",
};
