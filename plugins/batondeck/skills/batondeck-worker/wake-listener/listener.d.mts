/** Types for the wake listener's pure logic (the .mjs ships to the plugin; the tests drive this). */
export declare const DEFAULT_MCP: string;
export declare const DEFAULT_CORE: string;
export declare const STS: string;
export declare const HEARTBEAT_MS: number;

export interface TokenHit {
  token: string;
  exp: number;
  sub: string;
}
export interface FakeFs {
  readdirSync?: (p: string) => string[];
  readFileSync?: (p: string, enc: string) => string;
  appendFileSync?: (p: string, data: string) => void;
  mkdirSync?: (p: string, o: { recursive: boolean }) => void;
}
export interface WakeNames {
  wpid?: string;
  subscription?: string;
  audience?: string;
  error?: string;
}
export interface Exchanged {
  accessToken?: string;
  expiresIn?: number;
  error?: string;
}
export interface Attached {
  outcome: 'listening';
  stop?: () => unknown;
  wpid: string;
  file: string;
}
export interface SubscribeArgs {
  subscription: string;
  accessToken: string;
  onDoorbell: (attributes: Record<string, string> | undefined) => void;
  onError: (reason: unknown) => void;
}

export declare function claimsOf(jwt: string): Record<string, unknown>;
export declare function findToken(opts?: { home?: string; issuer?: string; now?: () => number; fs?: FakeFs }): TokenHit | null;
export declare function wakeSession(o: { fetch: typeof fetch; core?: string; token: string; agentId?: string }): Promise<WakeNames>;
export declare function exchange(o: { fetch: typeof fetch; audience: string; token: string }): Promise<Exchanged>;
export declare function deliver(o: { file: string; record: unknown; fs?: FakeFs; dir?: string }): void;
export declare function deliveryFile(o: { home?: string; sessionId?: string }): { dir: string; file: string };
export declare function run(o?: {
  fetch?: typeof fetch;
  subscribe?: (a: SubscribeArgs) => () => unknown;
  sessionId?: string;
  agentId?: string;
  home?: string;
  core?: string;
  issuer?: string;
  now?: () => number;
  log?: (m: string) => void;
  fs?: FakeFs;
  heartbeatMs?: number;
  setTimer?: (fn: () => void, ms: number) => unknown;
  clearTimer?: (t: unknown) => void;
}): Promise<string | Attached>;
