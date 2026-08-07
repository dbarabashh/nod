import type { User } from "https://esm.sh/@supabase/supabase-js@2.47.10";
import { json } from "./http.ts";
import { authenticate } from "./supabase.ts";

export const CONNECTOR_PERMISSION = "meetings:read";

export interface ConnectorClaims {
    aud?: string | string[];
    client_id?: string;
    exp?: number;
    iss?: string;
    nod_permissions?: string[];
    role?: string;
    sub?: string;
}

export interface ConnectorIdentity {
    claims: ConnectorClaims;
    token: string;
    user: User;
}

export function decodeConnectorClaims(token: string): ConnectorClaims | null {
    const parts = token.split(".");
    if (parts.length !== 3) return null;
    try {
        const base64 = parts[1].replace(/-/g, "+").replace(/_/g, "/");
        const padded = base64.padEnd(Math.ceil(base64.length / 4) * 4, "=");
        return JSON.parse(atob(padded)) as ConnectorClaims;
    } catch {
        return null;
    }
}

function bearer(req: Request): string | null {
    const match = (req.headers.get("Authorization") ?? "").match(/^Bearer\s+([^\s]+)$/i);
    return match?.[1] ?? null;
}

function hasAudience(claims: ConnectorClaims, resourceUri: string): boolean {
    return Array.isArray(claims.aud) ? claims.aud.includes(resourceUri) : claims.aud === resourceUri;
}

export function connectorClaimsValid(
    claims: ConnectorClaims | null,
    userId: string,
    resourceUri: string,
    issuer: string,
    now = Math.floor(Date.now() / 1000),
): boolean {
    return Boolean(claims &&
        claims.iss === issuer &&
        hasAudience(claims, resourceUri) &&
        claims.sub === userId &&
        typeof claims.client_id === "string" &&
        claims.client_id.length > 0 &&
        claims.role === "mcp_connector" &&
        Array.isArray(claims.nod_permissions) &&
        claims.nod_permissions.includes(CONNECTOR_PERMISSION) &&
        typeof claims.exp === "number" &&
        claims.exp > now);
}

export function oauthChallenge(resourceMetadataUri: string, error?: string): string {
    const fields = [`resource_metadata="${resourceMetadataUri}"`];
    if (error) fields.push(`error="${error}"`);
    return `Bearer ${fields.join(", ")}`;
}

export function unauthorized(resourceMetadataUri: string, error = "invalid_token"): Response {
    return json(
        { error },
        401,
        { "WWW-Authenticate": oauthChallenge(resourceMetadataUri, error) },
    );
}

export async function authenticateConnector(
    req: Request,
    resourceUri: string,
    issuer: string,
    resourceMetadataUri: string,
): Promise<ConnectorIdentity | Response> {
    const token = bearer(req);
    if (!token) return unauthorized(resourceMetadataUri);

    const verified = await authenticate(req);
    if (verified instanceof Response) return unauthorized(resourceMetadataUri);

    const claims = decodeConnectorClaims(token);
    const valid = connectorClaimsValid(claims, verified.user.id, resourceUri, issuer);

    return valid && claims ? { claims, token, user: verified.user } : unauthorized(resourceMetadataUri);
}
