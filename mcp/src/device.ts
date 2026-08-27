/**
 * Finding and talking to the agent API on a running instrumented app.
 *
 * The app's HTTP viewer port is derived from its inspection port (`port + 101`),
 * which defaults to 47164 and may shift when the developer sets `XPECTOR_PORT`
 * or enables port fallback. Rather than making the user hunt for the number, the
 * server probes the documented range and remembers what answered.
 */

/** Default inspection ports the SDK binds (see `XPConstants.simulatorPortRange`). */
const BASE_PORTS = [47164, 47165, 47166, 47167, 47168, 47169];
/** The viewer/agent-API port sits at `base + 101`. */
const VIEWER_OFFSET = 101;

export interface Discovery {
  baseUrl: string;
  appName: string;
  protocolVersion: string;
  capabilities: string[];
  buffers: Record<string, number>;
}

export class XpectorError extends Error {}

/** Candidate base URLs, most likely first, honouring explicit configuration. */
function candidates(): string[] {
  const seen = new Set<string>();
  const out: string[] = [];
  const add = (url: string) => {
    const trimmed = url.replace(/\/+$/, '');
    if (!seen.has(trimmed)) {
      seen.add(trimmed);
      out.push(trimmed);
    }
  };

  // An explicit URL wins outright — this is how you reach a device on the LAN
  // or a relay, neither of which is on loopback.
  const explicit = process.env.XPECTOR_URL ?? argValue('--url');
  if (explicit) add(explicit);

  const port = process.env.XPECTOR_PORT ?? argValue('--port');
  if (port) add(`http://127.0.0.1:${Number(port) + VIEWER_OFFSET}`);

  const host = process.env.XPECTOR_HOST ?? '127.0.0.1';
  for (const base of BASE_PORTS) add(`http://${host}:${base + VIEWER_OFFSET}`);
  return out;
}

function argValue(flag: string): string | undefined {
  const index = process.argv.indexOf(flag);
  if (index >= 0 && index + 1 < process.argv.length) return process.argv[index + 1];
  const inline = process.argv.find((a) => a.startsWith(`${flag}=`));
  return inline?.slice(flag.length + 1);
}

async function fetchWithTimeout(url: string, ms: number): Promise<Response> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), ms);
  try {
    return await fetch(url, { signal: controller.signal });
  } finally {
    clearTimeout(timer);
  }
}

/**
 * Talks to one instrumented app, rediscovering it when it moves.
 *
 * The connection is deliberately re-validated rather than cached forever: over a
 * debugging session the app gets rebuilt, relaunched and sometimes lands on a
 * different port, and an agent should not have to be told to reconnect.
 */
export class XpectorClient {
  private baseUrl: string | null = null;

  /** Locates the app, preferring the last URL that worked. */
  async discover(force = false): Promise<Discovery> {
    if (force) this.baseUrl = null;

    const urls = this.baseUrl ? [this.baseUrl, ...candidates()] : candidates();
    const tried: string[] = [];

    for (const url of urls) {
      if (tried.includes(url)) continue;
      tried.push(url);
      try {
        const response = await fetchWithTimeout(`${url}/api`, 1500);
        if (!response.ok) continue;

        const body = (await response.json()) as any;
        if (body?.service !== 'xpector-agent-api') continue;

        this.baseUrl = url;
        return {
          baseUrl: url,
          appName: body.appName ?? 'unknown',
          protocolVersion: body.protocolVersion ?? 'unknown',
          capabilities: body.capabilities ?? [],
          buffers: body.buffers ?? {},
        };
      } catch {
        // Nothing listening, or something that is not Xpector. Try the next.
      }
    }

    throw new XpectorError(
      `No instrumented app answered on ${tried.join(', ')}.\n\n` +
        'Check that: the app is running and in the foreground; it links the XpectorServer product; ' +
        'it is a DEBUG build (or calls startForDevelopment); and XPECTOR_DISABLED is not set. ' +
        'For a device or a non-default port, set XPECTOR_URL to the URL the app prints at launch ' +
        '("[Xpector] Log stream: http://…").',
    );
  }

  private async base(): Promise<string> {
    if (this.baseUrl) return this.baseUrl;

    return (await this.discover()).baseUrl;
  }

  /** GETs an agent-API path, rediscovering once if the app has moved. */
  async get(path: string, params: Record<string, unknown> = {}, retry = true): Promise<Response> {
    const base = await this.base();
    const url = new URL(base + path);
    for (const [key, value] of Object.entries(params)) {
      if (value === undefined || value === null || value === '') continue;
      url.searchParams.set(key, String(value));
    }

    try {
      const response = await fetchWithTimeout(url.toString(), 30_000);
      if (response.status === 404 || response.ok) return response;
      if (response.status >= 500 && retry) throw new Error('retry');
      return response;
    } catch (error) {
      if (!retry) throw error;

      // The app was probably relaunched onto another port mid-session.
      this.baseUrl = null;
      await this.discover(true);
      return this.get(path, params, false);
    }
  }

  async text(path: string, params: Record<string, unknown> = {}): Promise<string> {
    const response = await this.get(path, { ...params, format: 'text' });
    const body = await response.text();
    if (!response.ok) throw new XpectorError(errorMessage(body, response.status));

    return body.trim() || '(empty)';
  }

  async json<T = any>(path: string, params: Record<string, unknown> = {}): Promise<T> {
    const response = await this.get(path, params);
    const body = await response.text();
    if (!response.ok) throw new XpectorError(errorMessage(body, response.status));

    return JSON.parse(body) as T;
  }
}

function errorMessage(body: string, status: number): string {
  try {
    const parsed = JSON.parse(body);
    if (parsed?.error) return String(parsed.error);
  } catch {
    // Not JSON — fall through to the raw body.
  }
  return `HTTP ${status}: ${body.slice(0, 300)}`;
}
