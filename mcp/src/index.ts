#!/usr/bin/env node
/**
 * xpector-mcp — lets an AI agent inspect a running iOS app.
 *
 * XpectorKit already streams an app's logs, network traffic, WebSocket frames,
 * view hierarchy and screen to a browser. This server exposes the same state as
 * MCP tools, so an agent debugging an iOS app can read what the app is actually
 * doing instead of guessing from source.
 *
 * Every tool returns the device's compact text rendering rather than raw JSON:
 * the same information at roughly a third of the tokens, which is what makes
 * repeated polling affordable inside a context window. Tools that an agent may
 * want to post-process (`network_request`, `node`) return JSON instead.
 *
 * The whole surface is read-only. Nothing here can modify the app.
 */
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { z } from 'zod';
import { XpectorClient, XpectorError } from './device.js';

const client = new XpectorClient();

const server = new McpServer({ name: 'xpector', version: '0.1.0' });

type ToolResult = { content: Array<any>; isError?: boolean };

function textResult(text: string): ToolResult {
  return { content: [{ type: 'text', text }] };
}

/**
 * Wraps a handler so a device that is missing, asleep or mid-relaunch produces
 * an explanation the agent can act on rather than a stack trace.
 */
function guard(handler: (args: any) => Promise<ToolResult>) {
  return async (args: any): Promise<ToolResult> => {
    try {
      return await handler(args ?? {});
    } catch (error) {
      const message = error instanceof XpectorError ? error.message : String(error);
      return { content: [{ type: 'text', text: `Xpector: ${message}` }], isError: true };
    }
  };
}

server.registerTool(
  'xpector_status',
  {
    title: 'Xpector status',
    description:
      'Find the running instrumented app and report what it is, what the SDK can capture, and how much history is buffered. ' +
      'Call this first, or whenever another tool reports it cannot reach the app.',
    inputSchema: {},
  },
  guard(async () => {
    const discovery = await client.discover(true);
    const buffers = Object.entries(discovery.buffers)
      .map(([key, value]) => `${key}=${value}`)
      .join(' ');
    return textResult(
      `Connected to ${discovery.appName} at ${discovery.baseUrl}\n` +
        `protocol: ${discovery.protocolVersion}\n` +
        `buffered: ${buffers}\n` +
        `capabilities: ${discovery.capabilities.join(', ')}`,
    );
  }),
);

server.registerTool(
  'xpector_summary',
  {
    title: 'App summary',
    description:
      'One-call triage of the running app: current screen, visible text, live FPS and memory, recent error logs, failed network requests, and leaked view controllers. ' +
      'Start here when asked what is wrong with the app — then use the focused tools for detail.',
    inputSchema: {
      logs: z.number().int().min(0).max(100).optional().describe('How many recent error/warning log lines to include (default 15).'),
      network: z.number().int().min(0).max(100).optional().describe('How many recent failed requests to include (default 10).'),
    },
  },
  guard(async (args) => textResult(await client.text('/api/summary', args))),
);

server.registerTool(
  'xpector_logs',
  {
    title: 'Read app logs',
    description:
      "Read the app's captured logs (print, NSLog, os_log, and crash reports from previous launches). " +
      'Filter server-side with q/level/source so only relevant lines are returned. ' +
      'To follow a running app, pass the `cursor` from a previous call to get only new lines.',
    inputSchema: {
      q: z.string().optional().describe('Case-insensitive substring the message must contain.'),
      level: z.string().optional().describe('Comma-separated levels: print, nslog, error, warning, debug, crash, info, userDefaults.'),
      source: z.string().optional().describe('Comma-separated sources: stdout, stderr, osLog, crash, userDefaults.'),
      limit: z.number().int().min(1).max(1000).optional().describe('Maximum lines to return, newest kept (default 50).'),
      cursor: z.string().optional().describe('A `next:` cursor from an earlier call — returns only lines logged since.'),
      maxLen: z.number().int().min(40).max(20000).optional().describe('Truncate each message to this many characters (default 2000).'),
    },
  },
  guard(async ({ cursor, ...rest }) => textResult(await client.text('/api/logs', { ...rest, since: cursor }))),
);

server.registerTool(
  'xpector_network',
  {
    title: 'List network requests',
    description:
      'List HTTP requests the app made, as one line each. Bodies and headers are omitted — fetch them for a specific request with xpector_network_request. ' +
      'Use failedOnly to jump straight to what broke.',
    inputSchema: {
      q: z.string().optional().describe('Substring matched against the URL and error text.'),
      method: z.string().optional().describe('Comma-separated methods, e.g. "post,put".'),
      status: z.string().optional().describe('Status codes or classes, e.g. "404", "4xx,5xx".'),
      host: z.string().optional().describe('Comma-separated host substrings.'),
      minDuration: z.number().optional().describe('Only requests at least this many milliseconds — use to find slow calls.'),
      failedOnly: z.boolean().optional().describe('Only requests that errored or returned >= 400.'),
      limit: z.number().int().min(1).max(1000).optional().describe('Maximum requests to return, newest kept (default 50).'),
      cursor: z.string().optional().describe('A `next:` cursor from an earlier call — returns only requests made since.'),
    },
  },
  guard(async ({ cursor, ...rest }) => textResult(await client.text('/api/network', { ...rest, since: cursor }))),
);

server.registerTool(
  'xpector_network_request',
  {
    title: 'Inspect one request',
    description:
      'Full detail for one request: headers plus request and response bodies. Take the id from xpector_network. ' +
      'Sensitive headers and bodies are redacted by the SDK before they leave the device.',
    inputSchema: {
      id: z.string().describe('Request id from xpector_network.'),
      maxLen: z.number().int().min(100).max(200000).optional().describe('Truncate each body to this many characters (default 8000).'),
    },
  },
  guard(async ({ id, maxLen }) => {
    const detail = await client.json(`/api/network/${encodeURIComponent(id)}`, { maxLen });
    return textResult(JSON.stringify(detail, null, 2));
  }),
);

server.registerTool(
  'xpector_websockets',
  {
    title: 'Read WebSocket traffic',
    description:
      'WebSocket connections and their frames, newest last, grouped by connection. Binary frames are decoded to a protobuf field tree with no schema. ' +
      'Pass a connection id to follow one socket.',
    inputSchema: {
      connection: z.string().optional().describe('Connection id (or its prefix) to filter to one socket.'),
      kind: z.string().optional().describe('Comma-separated: connect, message, close.'),
      direction: z.string().optional().describe('Comma-separated: in, out.'),
      q: z.string().optional().describe('Substring matched against text payloads and the socket URL.'),
      limit: z.number().int().min(1).max(1000).optional().describe('Maximum events to return, newest kept (default 50).'),
      cursor: z.string().optional().describe('A `next:` cursor from an earlier call.'),
      maxLen: z.number().int().min(0).max(40000).optional().describe('Truncate each payload to this many characters (default 600).'),
    },
  },
  guard(async ({ cursor, ...rest }) => textResult(await client.text('/api/ws', { ...rest, since: cursor }))),
);

server.registerTool(
  'xpector_hierarchy',
  {
    title: 'Read the view hierarchy',
    description:
      'The live view tree with frames, tap points and layout warnings — pixels stripped and wrapper views collapsed so it fits in context. ' +
      'Use it to understand screen structure or chase a layout bug. ' +
      'On SwiftUI screens the text is missing until the accessibility tree is built — attach an accessibility client once (`maestro --device <udid> hierarchy`, or any XCUITest run) and it stays fixed for the rest of the app run. The response carries `primed=false` while it applies. List rows below the fold have no view until scrolled into range.',
    inputSchema: {
      maxNodes: z.number().int().min(1).max(5000).optional().describe('Node budget (default 400).'),
      maxDepth: z.number().int().min(1).max(200).optional().describe('Maximum tree depth (default 24).'),
      visibleOnly: z.boolean().optional().describe('Drop hidden and off-screen views (default true).'),
      collapseWrappers: z.boolean().optional().describe('Collapse anonymous single-child container views (default true).'),
      constraints: z.boolean().optional().describe('Include Auto Layout constraint descriptions (default false; verbose).'),
    },
  },
  guard(async (args) => textResult(await client.text('/api/hierarchy', args))),
);

server.registerTool(
  'xpector_find',
  {
    title: 'Find a view',
    description:
      'Find views by visible text, accessibility label or identifier, or class name — with each hit\'s frame, tap point and ancestor chain. ' +
      'Cheaper than pulling the whole hierarchy when you only need to locate one element. ' +
      'On SwiftUI screens a text query misses copy that is genuinely on screen until the accessibility tree is built — attach an accessibility client once (`maestro --device <udid> hierarchy`, or any XCUITest run) to fix it for the rest of the app run. A miss is not proof the text is absent; the response carries `primed=false` while it applies.',
    inputSchema: {
      q: z.string().optional().describe('Case-insensitive substring to match.'),
      cls: z.string().optional().describe('Restrict to views whose class name contains this.'),
      limit: z.number().int().min(1).max(200).optional().describe('Maximum hits (default 25).'),
      visibleOnly: z.boolean().optional().describe('Search only visible, on-screen views (default true).'),
    },
  },
  guard(async (args) => {
    if (!args.q && !args.cls) throw new XpectorError('Pass q (text to match) and/or cls (class name).');

    return textResult(await client.text('/api/find', args));
  }),
);

server.registerTool(
  'xpector_node',
  {
    title: 'Inspect one view',
    description:
      'Every attribute of one view — layout, colors, accessibility, and type-specific properties for labels, buttons, scroll views, stack views and more. ' +
      'Takes a `#ref` printed by xpector_hierarchy or xpector_find.',
    inputSchema: {
      ref: z.string().describe('A node ref such as "a1b2c3d4" (the # is optional), or a full node UUID.'),
    },
  },
  guard(async ({ ref }) => {
    const detail = await client.json(`/api/node/${encodeURIComponent(String(ref).replace(/^#/, ''))}`);
    return textResult(JSON.stringify(detail, null, 2));
  }),
);

server.registerTool(
  'xpector_screenshot',
  {
    title: 'Screenshot the app',
    description:
      'The current screen as an image. Always reflects what is actually displayed, which makes it the fallback for reading a SwiftUI screen whose accessibility tree has not been built yet.',
    inputSchema: {},
  },
  guard(async () => {
    const shot = await client.json<{ base64: string; mimeType: string }>('/api/screen', { encoding: 'base64' });
    return { content: [{ type: 'image', data: shot.base64, mimeType: shot.mimeType }] };
  }),
);

server.registerTool(
  'xpector_navigation',
  {
    title: 'Navigation history',
    description: 'The screens the user moved through — pushes, pops, presents, dismisses and tab switches, in order.',
    inputSchema: {
      limit: z.number().int().min(1).max(1000).optional().describe('Maximum events (default 50).'),
    },
  },
  guard(async (args) => textResult(await client.text('/api/nav', args))),
);

server.registerTool(
  'xpector_diagnostics',
  {
    title: 'Leaks and performance',
    description:
      'View controllers that failed to deallocate, alongside live FPS, memory, hang count and dropped frames. ' +
      'Use after exercising a flow to check it cleaned up.',
    inputSchema: {},
  },
  guard(async () => {
    const [leaks, perf] = await Promise.all([
      client.text('/api/leaks'),
      client.json<{ perf: Record<string, number> | null }>('/api/perf'),
    ]);

    const performance = perf.perf
      ? `fps ${perf.perf.currentFPS.toFixed(0)} (avg ${perf.perf.avgFPS.toFixed(0)}), ` +
        `memory ${perf.perf.memoryUsageMB.toFixed(0)} MB (peak ${perf.perf.peakMemoryMB.toFixed(0)}), ` +
        `${perf.perf.recentHangCount} hangs, ${perf.perf.droppedFrames} dropped frames, ` +
        `up ${perf.perf.uptimeSeconds.toFixed(0)}s`
      : 'performance capture is off';

    return textResult(`leaks:\n${leaks}\n\nperformance:\n${performance}`);
  }),
);

const transport = new StdioServerTransport();
await server.connect(transport);
