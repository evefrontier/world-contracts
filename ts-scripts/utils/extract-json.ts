import * as fs from "node:fs";

function readStdin(): Promise<string> {
    return new Promise((resolve, reject) => {
        let data = "";
        process.stdin.setEncoding("utf8");
        process.stdin.on("data", (chunk) => (data += chunk));
        process.stdin.on("end", () => resolve(data));
        process.stdin.on("error", reject);
    });
}

export function extractJson(text: string): string {
    const start = text.indexOf("{");
    const end = text.lastIndexOf("}");
    if (start === -1 || end === -1 || end < start) {
        throw new Error("No JSON found in input");
    }
    return text.slice(start, end + 1);
}

async function main() {
    const filePath = process.argv[2];
    const raw = filePath ? fs.readFileSync(filePath, "utf8") : await readStdin();
    const jsonText = extractJson(raw);

    const parsed = JSON.parse(jsonText) as unknown;
    process.stdout.write(JSON.stringify(parsed, null, 2) + "\n");
}

main().catch((err) => {
    const msg = err instanceof Error ? err.message : String(err);
    process.stderr.write(`extract-json: ${msg}\n`);
    process.exit(1);
});
