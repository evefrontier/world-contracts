/**
 * Shared delay helper. Use getDelayMs() when waiting between sequential txs (reads DELAY_SECONDS env).
 */
export function delay(ms: number): Promise<void> {
    return new Promise((resolve) => setTimeout(resolve, ms));
}

export function getDelayMs(): number {
    return Number(process.env.DELAY_SECONDS ?? 2) * 1000;
}
