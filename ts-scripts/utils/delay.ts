/**
 * Shared delay helper. Use getDelayMs() when waiting between sequential txs (reads DELAY_SECONDS env).
 */
export function delay(ms: number): Promise<void> {
    return new Promise((resolve) => setTimeout(resolve, ms));
}

export function getDelayMs(): number {
    const raw = process.env.DELAY_SECONDS;
    const parsed = raw !== undefined ? Number(raw) : NaN;
    const seconds = Number.isFinite(parsed) && parsed > 0 ? parsed : 3;
    return seconds * 1000;
}
